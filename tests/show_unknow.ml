#!/usr/bin/env ocaml

let () =
  try Topdirs.dir_directory (Sys.getenv "OCAML_TOPLEVEL_PATH")
  with Not_found -> ()
;;

#use "topfind";;
#require "str";;

(******************************************************************************)

let unknown = Str.regexp "(unknown)"

let check_unknown f =
  let ic = open_in f in
  let r = input_line ic in
  close_in ic;
  let pos = try Str.search_forward unknown r 0 with _ -> (-1) in
  if pos >= 0 then true
  else false

let print_info travis f =
  let ic = open_in f in
  let r = input_line ic in
  close_in ic;
  let name = Filename.chop_extension (Filename.basename f) in
  Printf.printf "[%s]:\t%s\n%!" name r
(*  let test_file = (Filename.chop_extension f) ^ ".result" in
  let cmd = Printf.sprintf "google-chrome %s >/dev/null 2>&1" test_file in
  Sys.command cmd
  |> (fun rc -> if rc <> 0 then Printf.printf "failed to open %s\n%!" test_file);
  match travis with
  | Some _ ->
     let uri =
       Printf.sprintf "https://travis-ci.org/ocaml/opam-repository/jobs/%s"
         name in
     let cmd = Printf.sprintf "google-chrome %s >/dev/null 2>&1" uri in
     ignore (Sys.command cmd)
  | None -> ()*)

let shorten_to lim lst =
  let rec aux cnt acc = function
    | hd :: tl -> if cnt >= lim then acc
                  else aux (cnt + 1) (hd :: acc) tl
    | [] -> acc in
  if lim = (-1) then lst else aux 0 [] lst

let () =
  let dir = Filename.concat (Sys.getcwd ()) Sys.argv.(1) in
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".result")
  |> List.map (fun f -> Filename.concat dir f)
  |> List.filter check_unknown
  |> (fun lst -> Printf.printf "There are total %d (unkown) in the results.\n%!"
       (List.length lst); lst)
(*  |> shorten_to (try int_of_string Sys.argv.(2) with _ -> (-1)) *)
  |> List.iter (print_info (try Some (Sys.argv.(3)) with _ -> None))
