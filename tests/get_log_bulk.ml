#!/usr/bin/env ocaml

let () =
  try Topdirs.dir_directory (Sys.getenv "OCAML_TOPLEVEL_PATH")
  with Not_found -> ()
;;

#use "topfind";;
#require "lwt";;
#require "lwt.unix";;
#require "unix";;
#require "netclient";;
#require "netstring";;

(******************************************************************************)

let get_html_elements uri =
  let raw = Nethttp_client.Convenience.http_get uri in
  let ioc = new Netchannels.input_string raw in
  Nethtml.parse ioc


let rec collect_elements num f documents = Nethtml.(
  let cnt = ref 0 in
  let rec aux accu = function
    | (Element (tag, args, c) as e) :: tl ->
       if !cnt = num then accu
       else if f tag args then begin incr cnt; aux (e :: accu) tl end
       else aux accu (c @ tl)
    | Data _ :: tl -> aux accu tl
    | [] -> accu in
  aux [] documents)


let unwrap_elem = Nethtml.(function
  | Element (t, args, c) -> t, args, c
  | Data d -> raise (Invalid_argument ("unwrap_elem " ^ d)))


let unwrap_data = Nethtml.(function
  | Data d -> d
  | Element _ -> raise (Invalid_argument ("unwrap_data")))


let get_latest_build digest =
  let f tag args =
    tag = "a"
    && String.length (List.assoc "href" args) = 40 in
  let a = collect_elements 1 f digest in
  let _, args, _ = unwrap_elem (List.hd a) in
  List.assoc "href" args


let is_err_link tag args =
  if tag = "td" then
    let cls = try List.assoc "class" args with _ -> "" in
    cls = "err"
  else false


let link_of_err_td td =
  let _, _, c = unwrap_elem td in
  let _, args, _ = unwrap_elem (List.hd c) in
  List.assoc "href" args


let compact_hrefs lst =
  let rec aux accu = function
    | hd :: tl -> if List.mem hd accu then aux accu tl
                  else aux (hd :: accu) tl
    | [] -> accu in
  aux [] lst


let rec string_of_doc = Nethtml.(function
  | Data d -> Printf.sprintf "data:%s" d
  | Element (t, args, c) -> begin
      let c_str = Printf.sprintf "[%s]"
        (String.concat ";" (List.map string_of_doc c)) in
      let arg_str = String.concat " "
        (List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) args) in
      Printf.sprintf "elem:<%s %s>%s</%s>" t arg_str c_str t end)


let string_of_doc_lst lst = Lwt.(
  let body = List.hd (collect_elements 1 (fun t _ -> t = "body") lst) in
  let _, _, children = unwrap_elem body in
  let pre =
    let cnt = ref 0 in
    List.fold_left (fun accu e ->
      try
        let t, _, _ = unwrap_elem e in
        if t = "hr" then begin incr cnt; accu end
        else if t = "pre" && !cnt >= 2 then e :: accu
        else accu
      with _ -> accu) [] children in
  Lwt_list.map_s (fun p ->
    let _, _, c = unwrap_elem p in
    let data = try List.hd c with _ -> Nethtml.Data "" in
    return (unwrap_data data)) (List.rev pre)
  >>= (fun str_lst -> return (String.concat "\n" str_lst)))


let log_of_string dir uri str =
  let pkg = Filename.chop_extension (Filename.basename uri) in
  let target = Filename.basename (Filename.dirname (Filename.dirname uri)) in
  let file = target ^ "-" ^ pkg ^ ".test" in
  let path = Filename.concat dir file in
  let oc = open_out path in
  output_string oc str; close_out oc;
  Printf.printf "Write log to: %s\n%!" path;
  Lwt.return ()

let () =
  let base_uri = "http://opam.ocaml.org/builds/" in
  let build_digest = get_html_elements  base_uri in
  let latest_build_href = get_latest_build build_digest in
  let build_table = get_html_elements (base_uri ^ latest_build_href) in
  print_endline (base_uri ^ latest_build_href);

  let log_num = try (int_of_string Sys.argv.(1)) with _ -> 20 in
  let err_tds = collect_elements (2 * log_num) is_err_link build_table in
  let log_hrefs = List.map link_of_err_td err_tds in
  let log_uris = List.map (fun h ->
    base_uri ^ latest_build_href ^ "/" ^ h) (compact_hrefs log_hrefs) in

  let download_logs = Lwt.(
    let download_one dir uri =
      return uri
      >>= (fun uri -> return (get_html_elements uri))
      >>= string_of_doc_lst
      >>= log_of_string dir uri in
    let dir = Filename.concat (Sys.getcwd ()) "bulk_tests" in
    if not (Sys.file_exists dir) then Unix.mkdir dir 0o775;
    Lwt_list.iter_p (download_one dir) log_uris) in
  Lwt_main.run download_logs
