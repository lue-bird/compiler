module Compiler.Optimize.Port exposing
    ( toDecoder
    , toEncoder
    , toFlagsDecoder
    )

import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Names as Names
import Data.Map as Dict exposing (Dict)
import Types as T
import Utils.Crash exposing (crash)



-- ENCODE


toEncoder : T.CASTC_Type -> Names.Tracker Opt.Expr
toEncoder tipe =
    case tipe of
        T.CASTC_TAlias _ _ args alias ->
            toEncoder (Type.dealias args alias)

        T.CASTC_TLambda _ _ ->
            crash "toEncoder: function"

        T.CASTC_TVar _ ->
            crash "toEncoder: type variable"

        T.CASTC_TUnit ->
            Names.fmap (Opt.Function [ Name.dollar ]) (encode "null")

        T.CASTC_TTuple a b c ->
            encodeTuple a b c

        T.CASTC_TType _ name args ->
            case args of
                [] ->
                    if name == Name.float then
                        encode "float"

                    else if name == Name.int then
                        encode "int"

                    else if name == Name.bool then
                        encode "bool"

                    else if name == Name.string then
                        encode "string"

                    else if name == Name.value then
                        Names.registerGlobal ModuleName.basics Name.identity_

                    else
                        crash "toEncoder: bad custom type"

                [ arg ] ->
                    if name == Name.maybe then
                        encodeMaybe arg

                    else if name == Name.list then
                        encodeList arg

                    else if name == Name.array then
                        encodeArray arg

                    else
                        crash "toEncoder: bad custom type"

                _ ->
                    crash "toEncoder: bad custom type"

        T.CASTC_TRecord _ (Just _) ->
            crash "toEncoder: bad record"

        T.CASTC_TRecord fields Nothing ->
            let
                encodeField : ( T.CDN_Name, T.CASTC_FieldType ) -> Names.Tracker Opt.Expr
                encodeField ( name, T.CASTC_FieldType _ fieldType ) =
                    toEncoder fieldType
                        |> Names.fmap
                            (\encoder ->
                                let
                                    value : Opt.Expr
                                    value =
                                        Opt.Call encoder [ Opt.Access (Opt.VarLocal Name.dollar) name ]
                                in
                                Opt.Tuple (Opt.Str (Name.toElmString name)) value Nothing
                            )
            in
            encode "object"
                |> Names.bind
                    (\object ->
                        Names.traverse encodeField (Dict.toList compare fields)
                            |> Names.bind
                                (\keyValuePairs ->
                                    Names.registerFieldDict fields
                                        (Opt.Function [ Name.dollar ] (Opt.Call object [ Opt.List keyValuePairs ]))
                                )
                    )



-- ENCODE HELPERS


encodeMaybe : T.CASTC_Type -> Names.Tracker Opt.Expr
encodeMaybe tipe =
    encode "null"
        |> Names.bind
            (\null ->
                toEncoder tipe
                    |> Names.bind
                        (\encoder ->
                            Names.registerGlobal ModuleName.maybe "destruct"
                                |> Names.fmap
                                    (\destruct ->
                                        Opt.Function [ Name.dollar ]
                                            (Opt.Call destruct
                                                [ null
                                                , encoder
                                                , Opt.VarLocal Name.dollar
                                                ]
                                            )
                                    )
                        )
            )


encodeList : T.CASTC_Type -> Names.Tracker Opt.Expr
encodeList tipe =
    encode "list"
        |> Names.bind
            (\list ->
                toEncoder tipe
                    |> Names.fmap (Opt.Call list << List.singleton)
            )


encodeArray : T.CASTC_Type -> Names.Tracker Opt.Expr
encodeArray tipe =
    encode "array"
        |> Names.bind
            (\array ->
                toEncoder tipe
                    |> Names.fmap (Opt.Call array << List.singleton)
            )


encodeTuple : T.CASTC_Type -> T.CASTC_Type -> Maybe T.CASTC_Type -> Names.Tracker Opt.Expr
encodeTuple a b maybeC =
    let
        let_ : T.CDN_Name -> T.CDI_ZeroBased -> Opt.Expr -> Opt.Expr
        let_ arg index body =
            Opt.Destruct (Opt.Destructor arg (Opt.Index index (Opt.Root Name.dollar))) body

        encodeArg : T.CDN_Name -> T.CASTC_Type -> Names.Tracker Opt.Expr
        encodeArg arg tipe =
            toEncoder tipe
                |> Names.fmap (\encoder -> Opt.Call encoder [ Opt.VarLocal arg ])
    in
    encode "list"
        |> Names.bind
            (\list ->
                Names.registerGlobal ModuleName.basics Name.identity_
                    |> Names.bind
                        (\identity ->
                            Names.bind
                                (\arg1 ->
                                    Names.bind
                                        (\arg2 ->
                                            case maybeC of
                                                Nothing ->
                                                    Names.pure
                                                        (Opt.Function [ Name.dollar ]
                                                            (let_ "a"
                                                                Index.first
                                                                (let_ "b"
                                                                    Index.second
                                                                    (Opt.Call list
                                                                        [ identity
                                                                        , Opt.List [ arg1, arg2 ]
                                                                        ]
                                                                    )
                                                                )
                                                            )
                                                        )

                                                Just c ->
                                                    Names.fmap
                                                        (\arg3 ->
                                                            Opt.Function [ Name.dollar ]
                                                                (let_ "a"
                                                                    Index.first
                                                                    (let_ "b"
                                                                        Index.second
                                                                        (let_ "c"
                                                                            Index.third
                                                                            (Opt.Call list
                                                                                [ identity
                                                                                , Opt.List [ arg1, arg2, arg3 ]
                                                                                ]
                                                                            )
                                                                        )
                                                                    )
                                                                )
                                                        )
                                                        (encodeArg "c" c)
                                        )
                                        (encodeArg "b" b)
                                )
                                (encodeArg "a" a)
                        )
            )



-- FLAGS DECODER


toFlagsDecoder : T.CASTC_Type -> Names.Tracker Opt.Expr
toFlagsDecoder tipe =
    case tipe of
        T.CASTC_TUnit ->
            Names.fmap (\succeed -> Opt.Call succeed [ Opt.Unit ])
                (decode "succeed")

        _ ->
            toDecoder tipe



-- DECODE


toDecoder : T.CASTC_Type -> Names.Tracker Opt.Expr
toDecoder tipe =
    case tipe of
        T.CASTC_TLambda _ _ ->
            crash "functions should not be allowed through input ports"

        T.CASTC_TVar _ ->
            crash "type variables should not be allowed through input ports"

        T.CASTC_TAlias _ _ args alias ->
            toDecoder (Type.dealias args alias)

        T.CASTC_TUnit ->
            decodeTuple0

        T.CASTC_TTuple a b c ->
            decodeTuple a b c

        T.CASTC_TType _ name args ->
            case ( name, args ) of
                ( "Float", [] ) ->
                    decode "float"

                ( "Int", [] ) ->
                    decode "int"

                ( "Bool", [] ) ->
                    decode "bool"

                ( "String", [] ) ->
                    decode "string"

                ( "Value", [] ) ->
                    decode "value"

                ( "Maybe", [ arg ] ) ->
                    decodeMaybe arg

                ( "List", [ arg ] ) ->
                    decodeList arg

                ( "Array", [ arg ] ) ->
                    decodeArray arg

                _ ->
                    crash "toDecoder: bad type"

        T.CASTC_TRecord _ (Just _) ->
            crash "toDecoder: bad record"

        T.CASTC_TRecord fields Nothing ->
            decodeRecord fields



-- DECODE MAYBE


decodeMaybe : T.CASTC_Type -> Names.Tracker Opt.Expr
decodeMaybe tipe =
    Names.bind
        (\nothing ->
            Names.bind
                (\just ->
                    Names.bind
                        (\oneOf ->
                            Names.bind
                                (\null ->
                                    Names.bind
                                        (\map_ ->
                                            Names.fmap
                                                (\subDecoder ->
                                                    Opt.Call oneOf
                                                        [ Opt.List
                                                            [ Opt.Call null [ nothing ]
                                                            , Opt.Call map_ [ just, subDecoder ]
                                                            ]
                                                        ]
                                                )
                                                (toDecoder tipe)
                                        )
                                        (decode "map")
                                )
                                (decode "null")
                        )
                        (decode "oneOf")
                )
                (Names.registerGlobal ModuleName.maybe "Just")
        )
        (Names.registerGlobal ModuleName.maybe "Nothing")



-- DECODE LIST


decodeList : T.CASTC_Type -> Names.Tracker Opt.Expr
decodeList tipe =
    Names.bind
        (\list ->
            Names.fmap (Opt.Call list << List.singleton)
                (toDecoder tipe)
        )
        (decode "list")



-- DECODE ARRAY


decodeArray : T.CASTC_Type -> Names.Tracker Opt.Expr
decodeArray tipe =
    Names.bind
        (\array ->
            Names.fmap (Opt.Call array << List.singleton)
                (toDecoder tipe)
        )
        (decode "array")



-- DECODE TUPLES


decodeTuple0 : Names.Tracker Opt.Expr
decodeTuple0 =
    Names.fmap (\null -> Opt.Call null [ Opt.Unit ])
        (decode "null")


decodeTuple : T.CASTC_Type -> T.CASTC_Type -> Maybe T.CASTC_Type -> Names.Tracker Opt.Expr
decodeTuple a b maybeC =
    Names.bind
        (\succeed ->
            case maybeC of
                Nothing ->
                    let
                        tuple : Opt.Expr
                        tuple =
                            Opt.Tuple (toLocal 0) (toLocal 1) Nothing
                    in
                    indexAndThen 1 b (Opt.Call succeed [ tuple ])
                        |> Names.bind (indexAndThen 0 a)

                Just c ->
                    let
                        tuple : Opt.Expr
                        tuple =
                            Opt.Tuple (toLocal 0) (toLocal 1) (Just (toLocal 2))
                    in
                    indexAndThen 2 c (Opt.Call succeed [ tuple ])
                        |> Names.bind (indexAndThen 1 b)
                        |> Names.bind (indexAndThen 0 a)
        )
        (decode "succeed")


toLocal : Int -> Opt.Expr
toLocal index =
    Opt.VarLocal (Name.fromVarIndex index)


indexAndThen : Int -> T.CASTC_Type -> Opt.Expr -> Names.Tracker Opt.Expr
indexAndThen i tipe decoder =
    Names.bind
        (\andThen ->
            Names.bind
                (\index ->
                    Names.fmap
                        (\typeDecoder ->
                            Opt.Call andThen
                                [ Opt.Function [ Name.fromVarIndex i ] decoder
                                , Opt.Call index [ Opt.Int i, typeDecoder ]
                                ]
                        )
                        (toDecoder tipe)
                )
                (decode "index")
        )
        (decode "andThen")



-- DECODE RECORDS


decodeRecord : Dict String T.CDN_Name T.CASTC_FieldType -> Names.Tracker Opt.Expr
decodeRecord fields =
    let
        toFieldExpr : T.CDN_Name -> b -> Opt.Expr
        toFieldExpr name _ =
            Opt.VarLocal name

        record : Opt.Expr
        record =
            Opt.Record (Dict.map toFieldExpr fields)
    in
    Names.bind
        (\succeed ->
            Names.registerFieldDict fields (Dict.toList compare fields)
                |> Names.bind
                    (\fieldDecoders ->
                        List.foldl (\fieldDecoder -> Names.bind (\optCall -> fieldAndThen optCall fieldDecoder))
                            (Names.pure (Opt.Call succeed [ record ]))
                            fieldDecoders
                    )
        )
        (decode "succeed")


fieldAndThen : Opt.Expr -> ( T.CDN_Name, T.CASTC_FieldType ) -> Names.Tracker Opt.Expr
fieldAndThen decoder ( key, T.CASTC_FieldType _ tipe ) =
    Names.bind
        (\andThen ->
            Names.bind
                (\field ->
                    Names.fmap
                        (\typeDecoder ->
                            Opt.Call andThen
                                [ Opt.Function [ key ] decoder
                                , Opt.Call field [ Opt.Str (Name.toElmString key), typeDecoder ]
                                ]
                        )
                        (toDecoder tipe)
                )
                (decode "field")
        )
        (decode "andThen")



-- GLOBALS HELPERS


encode : T.CDN_Name -> Names.Tracker Opt.Expr
encode name =
    Names.registerGlobal ModuleName.jsonEncode name


decode : T.CDN_Name -> Names.Tracker Opt.Expr
decode name =
    Names.registerGlobal ModuleName.jsonDecode name