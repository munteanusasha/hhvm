(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
*)
open Core
open IdeJson

module Cmd = ServerCommand
module Rpc = ServerCommandTypes
module SMUtils = ServerMonitorUtils

type env = {
  root: Path.t;
}

let rec connect_persistent env retries start_time =
  if retries < 0 then raise Exit_status.(Exit_with Out_of_retries);
  let connect_once_start_t = Unix.time () in

  let server_name = HhServerMonitorConfig.Program.hh_server in

  let conn = ServerUtils.connect_to_monitor env.root server_name in
  HackEventLogger.client_connect_once connect_once_start_t;
  match conn with
  | Result.Ok (ic, oc) ->
      (try
        ClientConnect.wait_for_server_hello ic env (Some retries)
          start_time None true;
      with
      | ClientConnect.Server_hung_up ->
        Exit_status.exit Exit_status.No_server_running
      );
      (ic, oc)
  | Result.Error e ->
    match e with
    | SMUtils.Monitor_connection_failure
    | SMUtils.Server_busy
      when retries > 0 -> connect_persistent env (retries-1) start_time
    | SMUtils.Monitor_connection_failure
    | SMUtils.Server_busy ->
      raise Exit_status.(Exit_with IDE_out_of_retries)
    | SMUtils.Server_died
    | SMUtils.Server_missing
    | SMUtils.Build_id_mismatched ->
      (* IDE mode doesn't handle (re-)starting the server - needs to be done
       * separately with hh start or similar. *)
      raise Exit_status.(Exit_with IDE_no_server)

let connect_persistent env ~retries =
  let start_time = Unix.time () in
  try
    let (ic, oc) = connect_persistent env retries start_time in
    HackEventLogger.client_established_connection start_time;
    Cmd.send_connection_type oc ServerCommandTypes.Persistent;
    (ic, oc)
  with
  | e ->
    HackEventLogger.client_establish_connection_exception e;
    raise e

let malformed_input () =
  raise Exit_status.(Exit_with IDE_malformed_request)

let pending_push_messages = Queue.create ()
let stdin_reader = Buffered_line_reader.create Unix.stdin

let rpc conn command =
  let res, push_messages = Cmd.rpc_persistent conn command in
  List.iter push_messages (fun x -> Queue.push x pending_push_messages);
  res

let read_push_message_from_server fd : ServerCommandTypes.push =
  let open ServerCommandTypes in
  match Marshal_tools.from_fd_with_preamble fd with
  | Response s -> failwith "unexpected response without a request"
  | Push m -> m

let get_next_push_message fd =
  if Queue.is_empty pending_push_messages
    then read_push_message_from_server fd
    else Queue.take pending_push_messages

let read_connection_response fd =
  let res = Marshal_tools.from_fd_with_preamble fd in
  match res with
  | ServerCommandTypes.Connected -> ()

let server_disconnected () =
  raise Exit_status.(Exit_with No_error)

let read_request () =
  try Buffered_line_reader.get_next_line stdin_reader
  with Unix.Unix_error _ -> malformed_input ()

let write_response res =
  Printf.printf "%s\n" res;
  flush stdout

let get_ready_message server_in_fd =
  if not @@ Queue.is_empty pending_push_messages then `Server else
  if Buffered_line_reader.has_buffered_content stdin_reader then `Stdin else
  let readable, _, _ = Unix.select
    [server_in_fd; Buffered_line_reader.get_fd stdin_reader] [] [] 1.0 in
  if readable = [] then `None
  else if List.mem readable server_in_fd then `Server
  else `Stdin

let handle conn id call =
match call with
| Auto_complete_call (path, pos) ->
  let raw_result =
    rpc conn (Rpc.IDE_AUTOCOMPLETE (path, pos)) in
  let result =
    List.map raw_result AutocompleteService.autocomplete_result_to_json in
  let result_field = (Hh_json.JSON_Array result) in
  print_endline @@ IdeJsonUtils.json_string_of_response id
    (Auto_complete_response result_field)
| Open_file_call (path, contents) ->
  rpc conn (Rpc.OPEN_FILE (path, contents))
| Close_file_call path ->
  rpc conn (Rpc.CLOSE_FILE path)
| Edit_file_call (path, edits) ->
  rpc conn (Rpc.EDIT_FILE (path, edits))
| Disconnect_call ->
  rpc conn (Rpc.DISCONNECT);
  server_disconnected ()
| Subscribe_diagnostic_call ->
  rpc conn (Rpc.SUBSCRIBE_DIAGNOSTIC id)
| Unsubscribe_diagnostic_call ->
  rpc conn (Rpc.UNSUBSCRIBE_DIAGNOSTIC id)
| Sleep_for_test ->
  Unix.sleep 1

let main env =
  Printexc.record_backtrace true;
  let ic, oc = connect_persistent env ~retries:800 in
  let fd = Unix.descr_of_out_channel oc in
  read_connection_response fd;
  while true do
    match get_ready_message fd with
    | `None -> ()
    | `Stdin ->
      let request = read_request () in
      begin
      match IdeJsonUtils.call_of_string request with
      | Call (id, call) ->
        handle (ic, oc) id call
      | Invalid_call (id, msg) ->
        print_endline msg
      | Parsing_error msg ->
        print_endline msg
      end
    | `Server ->
      let res = try get_next_push_message fd with
        | Marshal_tools.Reading_Preamble_Exception
        | Unix.Unix_error _ -> server_disconnected ()
      in
      match res with
      | ServerCommandTypes.DIAGNOSTIC (id, errors) ->
        SMap.iter begin fun path errors ->
          let diagnostic = {
            path;
            diagnostics = errors;
          } in
          write_response @@ IdeJsonUtils.json_string_of_response 0
            (Diagnostic_response (id, diagnostic))
        end errors
      | ServerCommandTypes.NEW_CLIENT_CONNECTED ->
        Printf.eprintf "Another persistent client have connected. Exiting.\n";
        raise Exit_status.(Exit_with IDE_new_client_connected)
  done;
  Exit_status.exit Exit_status.No_error
