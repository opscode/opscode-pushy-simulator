%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author James Casey <james@opscode.com>
%% @copyright 2012 Opscode Inc.

-record(client_state, {
          %% Zeromq Context
          ctx :: any(),

          client_name :: binary(),

          server_name :: binary(),
          server_port :: integer()

         }).

