%%%-------------------------------------------------------------------
%%% @author Bemwa Malak
%%% @copyright (C) 2024, Bemwa Malak
%%% @doc
%%% Module for handling message read status in ejabberd
%%% @end
%%%-------------------------------------------------------------------
-module(mod_message_status).
-author('Bemwa Malak').

%% Module behaviors
-behaviour(gen_mod).

-export([decode_iq_subel/1]).

%% gen_mod callbacks
-export([start/2,
         stop/1,
         depends/2,
         mod_options/1,
         mod_doc/0,
         mod_opt_type/1,
         mod_opt_get/2]).

%% API exports
-export([mark_as_read/3,
         mark_as_delivered/3,
         get_message_status/2,
         process_iq/1]).

%% Include files
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%% Define namespaces
-define(NS_MESSAGE_STATUS, <<"urn:xmpp:message-status:0">>).
-define(STATUS_TABLE, message_status).

%% Records
-record(message_status, {
    message_id :: binary(),
    from_jid  :: binary(),
    to_jid    :: binary(),
    read      :: boolean(),
    delivered :: boolean(),
    timestamp :: integer()
}).

%%====================================================================
%% Callback implementations
%%====================================================================

mod_doc() ->
    <<"
    <h1>mod_message_status</h1>
    <p>This module provides message read status tracking functionality.</p>

    <h2>Features</h2>
    <ul>
      <li>Message status storage and retrieval</li>
    </ul>

    <h2>Configuration</h2>
    <ul>
      <li><code>backend</code>: Storage backend (mnesia or sql)</li>
      <li><code>use_cache</code>: Whether to use caching</li>
      <li><code>cache_size</code>: Maximum cache size</li>
      <li><code>cache_life_time</code>: Cache lifetime in seconds</li>
    </ul>
    ">>.

mod_opt_type(backend) ->
    econf:enum([mnesia, sql]);
mod_opt_type(use_cache) ->
    econf:bool();
mod_opt_type(cache_size) ->
    econf:pos_int();
mod_opt_type(cache_life_time) ->
    econf:timeout(second);
mod_opt_type(_) ->
    [backend, use_cache, cache_size, cache_life_time].

mod_options(_Host) ->
    [{backend, mnesia},
     {use_cache, true},
     {cache_size, 1000},
     {cache_life_time, 3600}].

mod_opt_get(Host, Opt) ->
    gen_mod:get_module_opt(Host, ?MODULE, Opt).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, _Opts) ->
    ?INFO_MSG("Starting mod_message_status on host ~p", [Host]),

    %% Register IQ handlers
    try
        ?INFO_MSG("Attempting to register local IQ handler for namespace ~p", [?NS_MESSAGE_STATUS]),
        case gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_MESSAGE_STATUS,
                                         ?MODULE, process_iq) of
            ok ->
                ?INFO_MSG("Successfully registered local IQ handler", []);
            Error1 ->
                ?ERROR_MSG("Failed to register local IQ handler: ~p", [Error1])
        end,

        ?INFO_MSG("Attempting to register session manager IQ handler for namespace ~p", [?NS_MESSAGE_STATUS]),
        case gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_MESSAGE_STATUS,
                                         ?MODULE, process_iq) of
            ok ->
                ?INFO_MSG("Successfully registered session manager IQ handler", []);
            Error2 ->
                ?ERROR_MSG("Failed to register session manager IQ handler: ~p", [Error2])
        end
    catch
        E:R:S ->
            ?ERROR_MSG("Exception while registering IQ handlers: ~p:~p~n~p", [E, R, S])
    end,

    %% Create tables based on selected backend
    case mod_opt_get(Host, backend) of
        mnesia ->
            ?INFO_MSG("Creating Mnesia tables", []),
            create_mnesia_tables();
        sql ->
            ?INFO_MSG("Creating SQL tables", []),
            create_sql_tables(Host)
    end,
    ok.

stop(Host) ->
    ?INFO_MSG("Stopping mod_message_status on host ~p", [Host]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MESSAGE_STATUS),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MESSAGE_STATUS),
    ok.

depends(_Host, _Opts) ->
    [{mod_mam, hard}].


%%====================================================================
%% IQ Handlers
%%====================================================================

decode_iq_subel(El) -> El.


process_iq(IQ) ->
    From = xmpp:get_from(IQ),
    ?DEBUG("Processing IQ stanza:~nFrom: ~p~nIQ: ~p", [From, IQ]),
    ?DEBUG("IQ type: ~p", [IQ#iq.type]),
    ?DEBUG("IQ sub_els: ~p", [IQ#iq.sub_els]),

    case IQ#iq.sub_els of
        [] ->
            ?ERROR_MSG("Empty sub_els in IQ stanza", []),
            Error = xmpp:err_bad_request(<<"Empty request">>, ?NS_MESSAGE_STATUS),
            xmpp:make_error(IQ, Error);
        [SubEl | _] ->
            ?DEBUG("First sub_element: ~p", [SubEl]),
            case SubEl of
                #xmlel{name = <<"mark-read">>, attrs = Attrs} ->
                    process_mark_read(IQ, Attrs);
                #xmlel{name = <<"mark-delivered">>, attrs = Attrs} ->
                    process_mark_delivered(IQ, Attrs);
                #xmlel{name = <<"get-status">>, attrs = Attrs} ->
                    process_get_status(IQ, Attrs);
                _ ->
                    ?ERROR_MSG("Unknown sub_element: ~p", [SubEl]),
                    Error = xmpp:err_feature_not_implemented(<<"Unknown request">>, ?NS_MESSAGE_STATUS),
                    xmpp:make_error(IQ, Error)
            end
    end.

process_mark_read(IQ, Attrs) ->
    try
        MessageId = proplists:get_value(<<"id">>, Attrs),
        FromJID = proplists:get_value(<<"from">>, Attrs),
        ToJID = proplists:get_value(<<"to">>, Attrs),

        case {MessageId, FromJID, ToJID} of
            {undefined, _, _} ->
                throw({error, missing_id});
            {_, undefined, _} ->
                throw({error, missing_from});
            {_, _, undefined} ->
                throw({error, missing_to});
            _ ->
                ?DEBUG("Marking message as read:~nID: ~p~nFrom: ~p~nTo: ~p",
                       [MessageId, FromJID, ToJID]),

                case mark_as_read(MessageId, FromJID, ToJID) of
                    ok ->
                        ?DEBUG("Successfully marked message as read", []),
                        xmpp:make_iq_result(IQ);
                    {error, Reason} ->
                        ?ERROR_MSG("Failed to mark message as read: ~p", [Reason]),
                        Error = xmpp:err_internal_server_error(<<"Failed to mark as read">>, ?NS_MESSAGE_STATUS),
                        xmpp:make_error(IQ, Error)
                end
        end
    catch
        throw:{error, missing_id} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing message ID">>, ?NS_MESSAGE_STATUS));
        throw:{error, missing_from} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing from JID">>, ?NS_MESSAGE_STATUS));
        throw:{error, missing_to} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing to JID">>, ?NS_MESSAGE_STATUS));
        E:R:S ->
            ?ERROR_MSG("Error processing mark-read: ~p:~p~n~p", [E, R, S]),
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Invalid mark-read request">>, ?NS_MESSAGE_STATUS))
    end.


process_mark_delivered(IQ, Attrs) ->
    try
        MessageId = proplists:get_value(<<"id">>, Attrs),
        FromJID = proplists:get_value(<<"from">>, Attrs),
        ToJID = proplists:get_value(<<"to">>, Attrs),

        case {MessageId, FromJID, ToJID} of
            {undefined, _, _} ->
                throw({error, missing_id});
            {_, undefined, _} ->
                throw({error, missing_from});
            {_, _, undefined} ->
                throw({error, missing_to});
            _ ->
                ?DEBUG("Marking message as delivered:~nID: ~p~nFrom: ~p~nTo: ~p",
                       [MessageId, FromJID, ToJID]),

                case mark_as_delivered(MessageId, FromJID, ToJID) of
                    ok ->
                        ?DEBUG("Successfully marked message as delivered", []),
                        xmpp:make_iq_result(IQ);
                    {error, Reason} ->
                        ?ERROR_MSG("Failed to mark message as delivered: ~p", [Reason]),
                        Error = xmpp:err_internal_server_error(<<"Failed to mark as delivered">>, ?NS_MESSAGE_STATUS),
                        xmpp:make_error(IQ, Error)
                end
        end
    catch
        throw:{error, missing_id} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing message ID">>, ?NS_MESSAGE_STATUS));
        throw:{error, missing_from} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing from JID">>, ?NS_MESSAGE_STATUS));
        throw:{error, missing_to} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing to JID">>, ?NS_MESSAGE_STATUS));
        E:R:S ->
            ?ERROR_MSG("Error processing mark-delivered: ~p:~p~n~p", [E, R, S]),
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Invalid mark-delivered request">>, ?NS_MESSAGE_STATUS))
    end.

process_get_status(IQ, Attrs) ->
    try
        MessageId = proplists:get_value(<<"id">>, Attrs),
        JID = proplists:get_value(<<"jid">>, Attrs),

        case {MessageId, JID} of
            {undefined, _} ->
                throw({error, missing_id});
            {_, undefined} ->
                throw({error, missing_jid});
            _ ->
                ?DEBUG("Getting status for message:~nID: ~p~nJID: ~p", [MessageId, JID]),

                case get_message_status(MessageId, JID) of
                    {ok, Status} ->
                        Result = #xmlel{
                            name = <<"status">>,
                            attrs = [
                                {<<"xmlns">>, ?NS_MESSAGE_STATUS},
                                {<<"read">>, atom_to_list(Status#message_status.read)},
                                {<<"delivered">>, atom_to_list(Status#message_status.delivered)},
                                {<<"timestamp">>, integer_to_list(Status#message_status.timestamp)}
                            ]
                        },
                        ?DEBUG("Sending status response: ~p", [Result]),
                        xmpp:make_iq_result(IQ, Result);
                    {error, not_found} ->
                        ?INFO_MSG("Status not found for message ~p", [MessageId]),
                        Error = xmpp:err_item_not_found(<<"Message status not found">>, ?NS_MESSAGE_STATUS),
                        xmpp:make_error(IQ, Error);
                    {error, Reason} ->
                        ?ERROR_MSG("Failed to get message status: ~p", [Reason]),
                        Error = xmpp:err_internal_server_error(<<"Failed to get status">>, ?NS_MESSAGE_STATUS),
                        xmpp:make_error(IQ, Error)
                end
        end
    catch
        throw:{error, missing_id} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing message ID">>, ?NS_MESSAGE_STATUS));
        throw:{error, missing_jid} ->
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing JID">>, ?NS_MESSAGE_STATUS));
        E:R:S ->
            ?ERROR_MSG("Error processing get-status: ~p:~p~n~p", [E, R, S]),
            xmpp:make_error(IQ, xmpp:err_bad_request(<<"Invalid get-status request">>, ?NS_MESSAGE_STATUS))
    end.
%%====================================================================
%% Internal functions
%%====================================================================

create_mnesia_tables() ->
    case mnesia:create_table(message_status,
                            [{disc_copies, [node()]},
                             {attributes, record_info(fields, message_status)}]) of
        {atomic, ok} ->
            ?INFO_MSG("Successfully created Mnesia table", []),
            ok;
        {aborted, {already_exists, _}} ->
            ?INFO_MSG("Mnesia table already exists", []),
            ok;
        Error ->
            ?ERROR_MSG("Failed to create Mnesia table: ~p", [Error]),
            {error, Error}
    end.

create_sql_tables(Host) ->
    ?INFO_MSG("Creating SQL tables for host ~p", [Host]),
    SqlSchema = [
        "CREATE TABLE IF NOT EXISTS message_status (",
        "  message_id VARCHAR(255) NOT NULL,",
        "  from_jid VARCHAR(255) NOT NULL,",
        "  to_jid VARCHAR(255) NOT NULL,",
        "  read BOOLEAN DEFAULT FALSE,",
        "  delivered BOOLEAN DEFAULT FALSE,",
        "  timestamp BIGINT,",
        "  PRIMARY KEY (message_id)",
        ");"
    ],
    case catch ejabberd_sql:sql_query(Host, lists:concat(SqlSchema)) of
        {updated, _} ->
            ?INFO_MSG("Successfully created SQL table", []),
            ok;
        Error ->
            ?ERROR_MSG("Failed to create SQL table: ~p", [Error]),
            {error, Error}
    end.

%%====================================================================
%% Storage functions
%%====================================================================

mark_as_read(MessageId, FromJID, ToJID) ->
    ?INFO_MSG("Marking message ~p as read (From: ~p, To: ~p)", [MessageId, FromJID, ToJID]),
    Status = #message_status{
        message_id = MessageId,
        from_jid = FromJID,
        to_jid = ToJID,
        read = true,
        timestamp = erlang:system_time(second)
    },
    case mod_opt_get(global, backend) of
        mnesia -> update_mnesia(Status);
        sql -> update_sql(Status)
    end.

mark_as_delivered(MessageId, FromJID, ToJID) ->
    ?INFO_MSG("Marking message ~p as delivered (From: ~p, To: ~p)", [MessageId, FromJID, ToJID]),
    Status = #message_status{
        message_id = MessageId,
        from_jid = FromJID,
        to_jid = ToJID,
        delivered = true,
        timestamp = erlang:system_time(second)
    },
    case mod_opt_get(global, backend) of
        mnesia -> update_mnesia(Status);
        sql -> update_sql(Status)
    end.

get_message_status(MessageId, JID) ->
    ?INFO_MSG("Getting status for message ~p (JID: ~p)", [MessageId, JID]),
    case mod_opt_get(global, backend) of
        mnesia -> get_mnesia(MessageId, JID);
        sql -> get_sql(MessageId, JID)
    end.

update_mnesia(Status) ->
    F = fun() ->
        case mnesia:read({message_status, Status#message_status.message_id}) of
            [ExistingStatus] ->
                % Preserve existing values for fields not being updated
                UpdatedStatus = case {Status#message_status.read, Status#message_status.delivered} of
                    {undefined, true} ->
                        % Updating delivered status only
                        ExistingStatus#message_status{
                            delivered = true,
                            timestamp = Status#message_status.timestamp
                        };
                    {true, undefined} ->
                        % Updating read status only
                        ExistingStatus#message_status{
                            read = true,
                            timestamp = Status#message_status.timestamp
                        };
                    _ ->
                        % Fallback case: update both if somehow both are set
                        ExistingStatus#message_status{
                            read = Status#message_status.read orelse ExistingStatus#message_status.read,
                            delivered = Status#message_status.delivered orelse ExistingStatus#message_status.delivered,
                            timestamp = Status#message_status.timestamp
                        }
                end,
                mnesia:write(UpdatedStatus);
            [] ->
                % If no record exists, create a new one
                mnesia:write(Status)
        end
    end,
    case mnesia:transaction(F) of
        {atomic, ok} ->
            ?INFO_MSG("Successfully updated status in Mnesia", []),
            ok;
        Error ->
            ?ERROR_MSG("Failed to update status in Mnesia: ~p", [Error]),
            {error, Error}
    end.

get_mnesia(MessageId, JID) ->
    F = fun() ->
        case mnesia:match_object(#message_status{message_id = MessageId,
                                               from_jid = JID,
                                               _ = '_'}) of
            [Status] ->
                ?INFO_MSG("Found status in Mnesia", []),
                Status;
            [] ->
                ?INFO_MSG("Status not found in Mnesia, creating new one", []),
                NewStatus = #message_status{
                    message_id = MessageId,
                    from_jid = JID,
                    to_jid = JID,
                    read = false,
                    delivered = false,
                    timestamp = erlang:system_time(second)
                },
                case mnesia:write(NewStatus) of
                    ok ->
                        NewStatus;
                    WriteError ->
                        throw(WriteError)
                end
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Status} ->
            {ok, Status};
        {aborted, Reason} ->
            ?ERROR_MSG("Failed to query/write to Mnesia: ~p", [Reason]),
            {error, Reason};
        Error ->
            ?ERROR_MSG("Unexpected Mnesia error: ~p", [Error]),
            {error, Error}
    end.

update_sql(#message_status{} = Status) ->
    Host = get_host_from_jid(Status#message_status.from_jid),
    ?DEBUG("Updating status in SQL for host: ~p", [Host]),

    % Determine which field to update based on what's being marked
    {UpdateField, UpdateValue} = case {Status#message_status.read, Status#message_status.delivered} of
        {undefined, true} ->
            {"delivered", true};
        {true, undefined} ->
            {"read", true};
        _ ->
            {"read = ~w, delivered = ~w", {Status#message_status.read, Status#message_status.delivered}}
    end,

    F = fun() ->
        UpdateQuery = case UpdateField of
            {BothFields, {ReadVal, DeliveredVal}} ->
                io_lib:format(
                    "UPDATE message_status SET " ++ BothFields ++ ", timestamp = ~w WHERE message_id = '~s'",
                    [ReadVal, DeliveredVal, Status#message_status.timestamp, Status#message_status.message_id]
                );
            _ ->
                io_lib:format(
                    "UPDATE message_status SET " ++ UpdateField ++ " = ~w, timestamp = ~w WHERE message_id = '~s'",
                    [UpdateValue, Status#message_status.timestamp, Status#message_status.message_id]
                )
        end,

        case ejabberd_sql:sql_query_t(UpdateQuery) of
            {updated, N} when N > 0 ->
                {updated, N};
            {updated, 0} ->
                % If no row was updated, insert a new one
                InsertQuery = "INSERT INTO message_status "
                             "(message_id, from_jid, to_jid, read, delivered, timestamp) "
                             "VALUES ('~s', '~s', '~s', ~w, ~w, ~w)",

                % Set default values for the non-updated field
                {ReadValue, DeliveredValue} = case {Status#message_status.read, Status#message_status.delivered} of
                    {undefined, true} -> {false, true};
                    {true, undefined} -> {true, false};
                    _ -> {Status#message_status.read, Status#message_status.delivered}
                end,

                ejabberd_sql:sql_query_t(
                    io_lib:format(InsertQuery, [
                        Status#message_status.message_id,
                        Status#message_status.from_jid,
                        Status#message_status.to_jid,
                        ReadValue,
                        DeliveredValue,
                        Status#message_status.timestamp
                    ])
                );
            Error ->
                throw(Error)
        end
    end,

    case ejabberd_sql:sql_transaction(Host, F) of
        {atomic, {updated, _}} ->
            ?INFO_MSG("Successfully updated/inserted status in SQL transaction", []),
            ok;
        {atomic, {error, Reason}} ->
            ?ERROR_MSG("SQL transaction error: ~p", [Reason]),
            {error, Reason};
        {aborted, Reason} ->
            ?ERROR_MSG("SQL transaction aborted: ~p", [Reason]),
            {error, Reason};
        Error ->
            ?ERROR_MSG("Failed to execute SQL transaction: ~p", [Error]),
            {error, Error}
    end.

get_sql(MessageId, JID) ->
    Host = get_host_from_jid(JID),
    ?DEBUG("Getting status from SQL for host: ~p", [Host]),

    TimestampInt = erlang:system_time(second),
    SelectQuery = io_lib:format(
        "SELECT message_id, from_jid, to_jid, read, delivered, timestamp "
        "FROM message_status WHERE message_id = '~s'",
        [MessageId]
    ),

    case catch ejabberd_sql:sql_query(Host, SelectQuery) of
        {selected, _, [[MsgId, From, To, Read, Delivered, Timestamp]]} ->
            TimestampVal = try
                binary_to_integer(Timestamp)
            catch
                error:badarg ->
                    TimestampInt
            end,

            ReadBool = case Read of
                <<"t">> -> true;
                "t" -> true;
                true -> true;
                _ -> false
            end,

            DeliveredBool = case Delivered of
                <<"t">> -> true;
                "t" -> true;
                true -> true;
                _ -> false
            end,

            {ok, #message_status{
                message_id = MsgId,
                from_jid = From,
                to_jid = To,
                read = ReadBool,
                delivered = DeliveredBool,
                timestamp = TimestampVal
            }};
        {selected, _, []} ->
            % Return default values if no record found
            {ok, #message_status{
                message_id = MessageId,
                from_jid = JID,
                to_jid = JID,
                read = false,
                delivered = false,
                timestamp = TimestampInt
            }};
        {error, Reason} ->
            ?ERROR_MSG("SQL error: ~p", [Reason]),
            {error, Reason};
        Error ->
            ?ERROR_MSG("Failed to query SQL: ~p", [Error]),
            {error, Error}
    end.

get_host_from_jid(JID) when is_binary(JID) ->
    case binary:split(JID, <<"@">>) of
        [_, Host] ->
            case binary:split(Host, <<"/">>) of
                [ServerHost | _] -> ServerHost;
                _ -> Host
            end;
        _ -> <<"localhost">>
    end;

get_host_from_jid(_) ->
    <<"localhost">>.
