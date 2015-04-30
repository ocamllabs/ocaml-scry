#!/usr/bin/env ocaml

let () =
  try Topdirs.dir_directory (Sys.getenv "OCAML_TOPLEVEL_PATH")
  with Not_found -> ()
;;

#use "topfind";;
#require "unix";;

(******************************************************************************)

let from_test_dir dir_name =
  assert (Filename.check_suffix dir_name ".test");
  let dir = Filename.chop_extension dir_name in
  dir ^ ".result"


let test_one dir file =
  assert (Filename.check_suffix file ".test");
  let path = Filename.concat dir file in
  let cmd = Printf.sprintf "../intf.native %s" path in
  Unix.open_process_in cmd


let save_one dir file ic =
  let test_name = Filename.chop_extension file in
  let result_name = Filename.concat dir (test_name ^ ".result") in
  let oc = open_out result_name in
  begin try while true do
    let s = input_line ic in
    output_string oc (Printf.sprintf "%s\n" s)
  done with End_of_file | Sys_error _ -> () end;
  ignore (Unix.close_process_in ic);
  close_out oc;
  Printf.printf "Wrote scry results to: %s\n%!" result_name


let () =
  let test_dir = Filename.concat (Sys.getcwd ()) Sys.argv.(1) in
  Sys.readdir test_dir
  |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".test")
  |> List.iter (fun f -> test_one test_dir f |> save_one test_dir f)
