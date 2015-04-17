open Sexplib.Std

type r = {
  r_cmd : string;
  r_args : string list;
  r_env : string array;
  r_cwd : string;
  r_duration : Time.duration;
  r_stdout : string;
  r_stderr : string;
} with sexp

type proc_status =
  | Exited of int
  | Signaled of int
  | Stopped of int
with sexp

exception ProcessError of proc_status * r
