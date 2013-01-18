-module(couchapp).
-export([folder_to_json/1, sync/3, sync/4, compare/2]).

-include_lib("couchbeam/include/couchbeam.hrl").

% Options:
% {id, "some"}
% Host property = {host, "localhost"}
% Port property = {port, 10001}
% DB property = {db, "charging"}
defaults() -> ["127.0.0.1", 5984, "database"].

get_db_connection(Options) ->
    [Host, Port, DBPath] = attributes([host, port, db], defaults(), Options),
    DBOptions = case proplists:get_value(basic_auth, Options) of
                    undefined           -> [];
                    AuthorisationParams -> [{basic_auth, AuthorisationParams}]
                end,
    Server   = couchbeam:server_connection(Host, Port, "", DBOptions),
    {ok, DB} = couchbeam:open_db(Server, DBPath),
    DB.

sync(Folder, Docs, Options) ->
    sync(get_db_connection(Options), Folder, Docs, Options).

sync(DB, Folder, Docs, Options) ->
    {ok, {FolderProps}} = folder_to_json(Folder),
    sync_doc(DB, FolderProps, Docs, Options).

sync_doc(DB, FolderProps, Docs, Options) ->
    DDocId        = list_to_binary("_design/" ++ proplists:get_value(id, Options)),
    DDocLanguage  = proplists:get_value(language, Options, <<"javascript">>),
    NewProps      = [{<<"_id">>, DDocId}, {<<"language">>, DDocLanguage} | FolderProps],
    NewDesignDoc  = vmerge({NewProps}, {Docs}),
    io:format(user, "new design doc: ~p~n", [NewDesignDoc]),
    case couchbeam:open_doc(DB, DDocId) of
        {ok, {PropsInDB}} ->
            case compare(NewDesignDoc, {proplists:delete(<<"_rev">> , PropsInDB)}) of
                true ->
                    Rev = lists:keyfind(<<"_rev">>, 1, PropsInDB),
                    log_update(DB, DDocId),
                    couchbeam:save_doc(DB, {[Rev | NewProps]});
                false ->
                    ok
            end;
        {error, not_found} ->
            log_update(DB, DDocId),
            couchbeam:save_doc(DB, NewDesignDoc)
    end.

compare({Res}, {ObjInDB}) -> compare(Res, ObjInDB);
compare([], []) -> false;
compare([], _P) -> true;
compare([{Name, Content}|Res], ObjInDB) ->
    Resal = case proplists:get_value(Name, ObjInDB) of
                undefined ->
                    true;
                Value     ->
                    case {is_tuple(Content), is_tuple(Value)} of
                        {true, true}   -> compare(Content, Value);
                        {false, false} ->
                            case Content == Value of
                                true  -> false;
                                false -> true
                            end;
                        _Other        -> true
                    end
            end,
    case Resal of
        true  ->
            true;
        false ->
            compare(Res, proplists:delete(Name, ObjInDB))
    end.

attributes(Properties, Standarts, Options) ->
    attr_acc(Properties, Standarts, Options, []).

attr_acc([], _, _, Acc) -> lists:reverse(Acc);

attr_acc([Prop|Properties], [Stan|Standarts], Options, Acc) ->
    case proplists:get_value(Prop, Options) of
        undefined ->
            attr_acc(Properties, Standarts, Options, [Stan|Acc]);
        Value     ->
            attr_acc(Properties, Standarts, Options, [Value|Acc])
    end.

folder_to_json(Folder) ->
    case file:list_dir(Folder) of
        {ok, Files} ->
            {ok, {lists:flatmap(fun (F) -> do_entry(Folder, F) end, Files)}};
        Error ->
            Error
    end.

merge([{K1, V1} | R1], [{K2, V2} | R2]) when K1 == K2 ->
    [{K1, vmerge(V1, V2)} | merge(R1, R2)];
merge([{K1, V1} | R1], [{K2, V2} | R2]) when K1 < K2 ->
    [{K1, V1} | merge(R1, [{K2, V2} | R2])];
merge([{K1, V1} | R1], [{K2, V2} | R2]) when K1 > K2 ->
    [{K2, V2} | merge([{K1, V1} | R1], R2)];
merge([], []) ->
    [];
merge([], R2) ->
    R2;
merge(R1, []) ->
    R1.

vmerge({Json1}, {Json2}) ->
    {merge(lists:sort(Json1), lists:sort(Json2))};
vmerge(_, Value2) ->
    Value2.

do_entry(Dir, Name) ->
    case lists:reverse(Name) of
        [$~ | _] ->
            [];
        _Other ->
            do_entry_checked(Dir, Name)
    end.

do_entry_checked(_Dir, [$. | _]) ->
    [];
do_entry_checked(Directory, Name) ->
    Path = filename:join(Directory, Name),
    case filelib:is_dir(Path) of
        true ->
            {ok, DirContents} = folder_to_json(Path),
            [{list_to_binary(Name), DirContents}];
        false ->
            case file:read_file(Path) of
                {ok, Content} ->
                    [{list_to_binary(filename:rootname(Name)), Content}];
                {error, Error} ->
                    throw({error, Error})
            end
    end.

log_update(DB, DDoc) ->
    Report = io_lib:format("Pushing design document ~p~nCouchDB: ~s", [DDoc, get_db_url(DB)]),
    error_logger:info_report(Report).

get_db_url(#db{name = Name, server = Server}) ->
    couchbeam:make_url(Server, [Name], []).
