#!/usr/bin/env ocaml

let () =
  try Topdirs.dir_directory (Sys.getenv "OCAML_TOPLEVEL_PATH")
  with Not_found -> ()
;;

#use "topfind";;
#require "unix";;
#require "str";;

(******************************************************************************)

let escape_one_file f =
  let ic = open_in f in
  let buf = Buffer.create 128 in
  Buffer.add_channel buf ic (in_channel_length ic);
  let str = Buffer.contents buf in
  let re_lst = List.map (fun (re, templ) -> Str.regexp re, templ)
    [("&gt;", ">"); ("&lt;", "<"); ("&amp;", "&"); ("&quot;", "\"")] in
  let str_unescaped =
    List.fold_left (fun s (re, templ) ->
      Str.global_replace re templ s) str re_lst in
  close_in ic;
  let oc = open_out f in
  output_string oc str_unescaped;
  close_out oc

let () =
  let path = Filename.concat (Sys.getcwd ()) Sys.argv.(1) in
  if Sys.is_directory path then
    Sys.readdir path
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".test")
    |> List.map (fun f -> Filename.concat path f)
    |> List.iter escape_one_file
  else escape_one_file path
