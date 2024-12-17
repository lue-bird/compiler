module Compiler.Elm.Compiler.Type.Extract exposing
    ( Types(..)
    , Types_
    , fromDependencyInterface
    , fromInterface
    , fromMsg
    , fromType
    , merge
    , mergeMany
    , typesDecoder
    , typesEncoder
    )

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name
import Compiler.Elm.Compiler.Type as T
import Compiler.Elm.Interface as I
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Json.Decode as D
import Compiler.Json.Encode as E
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import Json.Decode as Decode
import Json.Encode as Encode
import Maybe.Extra as Maybe
import Types as T
import Utils.Main as Utils



-- EXTRACTION


fromType : T.CASTC_Type -> T.Type
fromType astType =
    Tuple.second (run (extract astType))


extract : T.CASTC_Type -> Extractor T.Type
extract astType =
    case astType of
        T.CASTC_TLambda arg result ->
            pure T.Lambda
                |> apply (extract arg)
                |> apply (extract result)

        T.CASTC_TVar x ->
            pure (T.Var x)

        T.CASTC_TType home name args ->
            addUnion (Opt.Global home name) (T.Type (toPublicName home name))
                |> apply (traverse extract args)

        T.CASTC_TRecord fields ext ->
            traverse (tupleTraverse extract) (Can.fieldsToList fields)
                |> fmap (\efields -> T.Record efields ext)

        T.CASTC_TUnit ->
            pure T.Unit

        T.CASTC_TTuple a b maybeC ->
            pure T.Tuple
                |> apply (extract a)
                |> apply (extract b)
                |> apply (traverse extract (Maybe.toList maybeC))

        T.CASTC_TAlias home name args aliasType ->
            addAlias (Opt.Global home name) ()
                |> bind
                    (\_ ->
                        extract (Type.dealias args aliasType)
                            |> bind
                                (\_ ->
                                    fmap (T.Type (toPublicName home name))
                                        (traverse (extract << Tuple.second) args)
                                )
                    )


toPublicName : T.CEMN_Canonical -> T.CDN_Name -> T.CDN_Name
toPublicName (T.CEMN_Canonical _ home) name =
    Name.sepBy '.' home name



-- TRANSITIVELY AVAILABLE TYPES


type Types
    = -- PERF profile Opt.Global representation
      -- current representation needs less allocation
      -- but maybe the lookup is much worse
      Types (Dict (List String) T.CEMN_Canonical Types_)


type Types_
    = Types_ (Dict String T.CDN_Name T.CASTC_Union) (Dict String T.CDN_Name T.CASTC_Alias)


mergeMany : List Types -> Types
mergeMany listOfTypes =
    case listOfTypes of
        [] ->
            Types Dict.empty

        t :: ts ->
            List.foldr merge t ts


merge : Types -> Types -> Types
merge (Types types1) (Types types2) =
    Types (Dict.union types1 types2)


fromInterface : T.CEMN_Raw -> T.CEI_Interface -> Types
fromInterface name (T.CEI_Interface pkg _ unions aliases _) =
    Types <|
        Dict.singleton ModuleName.toComparableCanonical (T.CEMN_Canonical pkg name) <|
            Types_ (Dict.map (\_ -> I.extractUnion) unions) (Dict.map (\_ -> I.extractAlias) aliases)


fromDependencyInterface : T.CEMN_Canonical -> I.DependencyInterface -> Types
fromDependencyInterface home di =
    Types
        (Dict.singleton ModuleName.toComparableCanonical home <|
            case di of
                I.Public (T.CEI_Interface _ _ unions aliases _) ->
                    Types_ (Dict.map (\_ -> I.extractUnion) unions) (Dict.map (\_ -> I.extractAlias) aliases)

                I.Private _ unions aliases ->
                    Types_ unions aliases
        )



-- EXTRACT MODEL, MSG, AND ANY TRANSITIVE DEPENDENCIES


fromMsg : Types -> T.CASTC_Type -> T.DebugMetadata
fromMsg types message =
    let
        ( msgDeps, msgType ) =
            run (extract message)

        ( aliases, unions ) =
            extractTransitive types noDeps msgDeps
    in
    T.DebugMetadata msgType aliases unions


extractTransitive : Types -> Deps -> Deps -> ( List T.Alias, List T.Union )
extractTransitive types (Deps seenAliases seenUnions) (Deps nextAliases nextUnions) =
    let
        aliases : EverySet (List String) Opt.Global
        aliases =
            EverySet.diff nextAliases seenAliases

        unions : EverySet (List String) Opt.Global
        unions =
            EverySet.diff nextUnions seenUnions
    in
    if EverySet.isEmpty aliases && EverySet.isEmpty unions then
        ( [], [] )

    else
        let
            ( newDeps, ( resultAlias, resultUnion ) ) =
                run
                    (pure Tuple.pair
                        |> apply (traverse (extractAlias types) (EverySet.toList Opt.compareGlobal aliases))
                        |> apply (traverse (extractUnion types) (EverySet.toList Opt.compareGlobal unions))
                    )

            oldDeps : Deps
            oldDeps =
                Deps (EverySet.union seenAliases nextAliases) (EverySet.union seenUnions nextUnions)

            ( remainingResultAlias, remainingResultUnion ) =
                extractTransitive types oldDeps newDeps
        in
        ( resultAlias ++ remainingResultAlias, resultUnion ++ remainingResultUnion )


extractAlias : Types -> Opt.Global -> Extractor T.Alias
extractAlias (Types dict) (Opt.Global home name) =
    let
        (T.CASTC_Alias args aliasType) =
            Utils.find ModuleName.toComparableCanonical home dict
                |> (\(Types_ _ aliasInfo) -> aliasInfo)
                |> Utils.find identity name
    in
    fmap (T.Alias (toPublicName home name) args) (extract aliasType)


extractUnion : Types -> Opt.Global -> Extractor T.Union
extractUnion (Types dict) (Opt.Global home name) =
    if name == Name.list && home == ModuleName.list then
        pure <| T.Union (toPublicName home name) [ "a" ] []

    else
        let
            pname : T.CDN_Name
            pname =
                toPublicName home name

            (T.CASTC_Union vars ctors _ _) =
                Utils.find ModuleName.toComparableCanonical home dict
                    |> (\(Types_ unionInfo _) -> unionInfo)
                    |> Utils.find identity name
        in
        fmap (T.Union pname vars) (traverse extractCtor ctors)


extractCtor : T.CASTC_Ctor -> Extractor ( T.CDN_Name, List T.Type )
extractCtor (T.CASTC_Ctor ctor _ _ args) =
    fmap (Tuple.pair ctor) (traverse extract args)



-- DEPS


type Deps
    = Deps (EverySet (List String) Opt.Global) (EverySet (List String) Opt.Global)


noDeps : Deps
noDeps =
    Deps EverySet.empty EverySet.empty



-- EXTRACTOR


type Extractor a
    = Extractor (EverySet (List String) Opt.Global -> EverySet (List String) Opt.Global -> EResult a)


type EResult a
    = EResult (EverySet (List String) Opt.Global) (EverySet (List String) Opt.Global) a


run : Extractor a -> ( Deps, a )
run (Extractor k) =
    case k EverySet.empty EverySet.empty of
        EResult aliases unions value ->
            ( Deps aliases unions, value )


addAlias : Opt.Global -> a -> Extractor a
addAlias alias value =
    Extractor <|
        \aliases unions ->
            EResult (EverySet.insert Opt.toComparableGlobal alias aliases) unions value


addUnion : Opt.Global -> a -> Extractor a
addUnion union value =
    Extractor <|
        \aliases unions ->
            EResult aliases (EverySet.insert Opt.toComparableGlobal union unions) value


fmap : (a -> b) -> Extractor a -> Extractor b
fmap func (Extractor k) =
    Extractor <|
        \aliases unions ->
            case k aliases unions of
                EResult a1 u1 value ->
                    EResult a1 u1 (func value)


pure : a -> Extractor a
pure value =
    Extractor (\aliases unions -> EResult aliases unions value)


apply : Extractor a -> Extractor (a -> b) -> Extractor b
apply (Extractor kv) (Extractor kf) =
    Extractor <|
        \aliases unions ->
            case kf aliases unions of
                EResult a1 u1 func ->
                    case kv a1 u1 of
                        EResult a2 u2 value ->
                            EResult a2 u2 (func value)


bind : (a -> Extractor b) -> Extractor a -> Extractor b
bind callback (Extractor ka) =
    Extractor <|
        \aliases unions ->
            case ka aliases unions of
                EResult a1 u1 value ->
                    case callback value of
                        Extractor kb ->
                            kb a1 u1


traverse : (a -> Extractor b) -> List a -> Extractor (List b)
traverse f =
    List.foldr (\a -> bind (\c -> fmap (\va -> va :: c) (f a)))
        (pure [])


tupleTraverse : (b -> Extractor c) -> ( a, b ) -> Extractor ( a, c )
tupleTraverse f ( a, b ) =
    fmap (Tuple.pair a) (f b)



-- ENCODERS and DECODERS


typesEncoder : Types -> Encode.Value
typesEncoder (Types types) =
    E.assocListDict ModuleName.compareCanonical ModuleName.canonicalEncoder types_Encoder types


typesDecoder : Decode.Decoder Types
typesDecoder =
    Decode.map Types (D.assocListDict ModuleName.toComparableCanonical ModuleName.canonicalDecoder types_Decoder)


types_Encoder : Types_ -> Encode.Value
types_Encoder (Types_ unionInfo aliasInfo) =
    Encode.object
        [ ( "type", Encode.string "Types_" )
        , ( "unionInfo", E.assocListDict compare Encode.string Can.unionEncoder unionInfo )
        , ( "aliasInfo", E.assocListDict compare Encode.string Can.aliasEncoder aliasInfo )
        ]


types_Decoder : Decode.Decoder Types_
types_Decoder =
    Decode.map2 Types_
        (Decode.field "unionInfo" (D.assocListDict identity Decode.string Can.unionDecoder))
        (Decode.field "aliasInfo" (D.assocListDict identity Decode.string Can.aliasDecoder))