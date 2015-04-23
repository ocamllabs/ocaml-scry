#!/usr/bin/env ocaml

let () =
  try Topdirs.dir_directory (Sys.getenv "OCAML_TOPLEVEL_PATH")
  with Not_found -> ()
;;
#use "topfind";;
#require "unix";;

(******************************************************************************)

let with_process_in cmd f =
  let ic = Unix.open_process_in cmd in
  try
    let r = f ic in
    ignore (Unix.close_process_in ic) ; r
  with exn ->
    ignore (Unix.close_process_in ic) ; raise exn

let read_file f =
  try
    let ic = open_in f in
    let lines = ref [] in
    begin
      try
        while true do
          let line = input_line ic in
          lines := line :: !lines;
        done
      with End_of_file | Sys_error _ -> ()
    end;
    close_in ic;
    List.rev !lines
  with Sys_error _ -> []

let red fmt = Printf.sprintf ("\027[31m"^^fmt^^"\027[m")
let green fmt = Printf.sprintf ("\027[32m"^^fmt^^"\027[m")
let show fmt = Printf.ksprintf (Printf.printf "%s\n%!") fmt
let errors = ref 0

let assert_equal msg x y =
  let res =
    if x = y then green "OK"
    else (
      incr errors;
      red "ERROR"
    ) in
  show "%s %s" msg res

let scry_cmd =
  if Sys.file_exists "../intf.byte" then "../intf.byte"
  else if Sys.file_exists "../intf.native" then "../intf.native"
  else failwith "Not scry command found."

let scry file = Printf.sprintf "%s %s" scry_cmd file

let one test =
  let file = test ^ ".test" in
  let result = read_file (test  ^ ".result") in
  with_process_in (scry file) (fun ic ->
      let msg = input_line ic in
      assert_equal test [msg] result
    )

let all tests =
  List.iter one tests;
  show "Run %d test(s): %d error(s)!" (List.length tests) !errors;
  if !errors <> 0 then exit 1

let () =
  let test_dir = Sys.argv.(1) in
  Sys.readdir (Filename.concat (Sys.getcwd ()) test_dir)
  |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".test")
  |> List.map (Filename.chop_extension)
  |> List.map (Filename.concat test_dir)
  |> all
