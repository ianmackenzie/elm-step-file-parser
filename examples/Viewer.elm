module Viewer exposing (main)

import Browser
import Bytes.Encode
import File exposing (File)
import File.Select
import Html exposing (Html)
import Html.Events
import Html.Keyed
import Html.Lazy
import List.Extra
import Set exposing (Set)
import Step.Decode as Decode
import Step.Format as Format
import Step.TypeName as TypeName
import Step.Types as Step
import Task


type alias Hidden a =
    () -> a


type DisplayedEntity
    = DisplayedEntity Step.Entity (List DisplayedEntity)


type alias Model =
    { displayedEntities : Maybe (Result String (Hidden (List DisplayedEntity)))
    }


type Msg
    = LoadRequested
    | FileSelected File
    | FileLoaded String
    | SetDisplayedEntity Int DisplayedEntity


unexpanded : Step.Entity -> DisplayedEntity
unexpanded entity =
    DisplayedEntity entity []


hide : a -> Hidden a
hide value =
    \() -> value


reveal : Hidden a -> a
reveal hidden =
    hidden ()


init : () -> ( Model, Cmd Msg )
init () =
    ( { displayedEntities = Nothing }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update message model =
    case message of
        LoadRequested ->
            ( model, File.Select.file [] FileSelected )

        FileSelected file ->
            ( model, Task.perform FileLoaded (File.toString file) )

        FileLoaded contents ->
            let
                parsedEntities =
                    Just <|
                        case Decode.file (Decode.allTopLevel Decode.identity) contents of
                            Ok entities ->
                                Ok (hide (List.map unexpanded entities))

                            Err (Decode.ParseError text) ->
                                Err ("STEP file parse error: " ++ text)

                            Err (Decode.NonexistentEntity id) ->
                                Err ("Nonexistent entity with id " ++ String.fromInt id ++ " referenced in STEP file")

                            Err (Decode.CircularReference ids) ->
                                Err ("Circular reference chain detected in STEP file: [" ++ String.join "," (List.map String.fromInt ids) ++ "]")

                            Err (Decode.DecodeError text) ->
                                Err ("STEP file decode error: " ++ text)
            in
            ( { model | displayedEntities = parsedEntities }, Cmd.none )

        SetDisplayedEntity index displayedEntity ->
            case model.displayedEntities of
                Nothing ->
                    ( model, Cmd.none )

                Just (Err _) ->
                    ( model, Cmd.none )

                Just (Ok displayedEntities) ->
                    let
                        currentDisplayedEntities =
                            reveal displayedEntities

                        updatedDisplayedEntities =
                            List.Extra.setAt index displayedEntity currentDisplayedEntities
                    in
                    ( { model | displayedEntities = Just (Ok (hide updatedDisplayedEntities)) }
                    , Cmd.none
                    )


entityRecordString : Step.TypeName -> List Step.Attribute -> String
entityRecordString typeName attributes =
    String.toLower (TypeName.toString typeName)
        ++ "("
        ++ String.join "," (List.map attributeString attributes)
        ++ ")"


entityString : Step.Entity -> String
entityString entity =
    case entity of
        Step.SimpleEntity typeName attributes ->
            entityRecordString typeName attributes

        Step.ComplexEntity entityRecords ->
            let
                entityRecordStrings =
                    List.map
                        (\( typeName, attributes ) ->
                            entityRecordString typeName attributes
                        )
                        entityRecords
            in
            "(" ++ String.concat entityRecordStrings ++ ")"


attributeString : Step.Attribute -> String
attributeString attribute =
    case attribute of
        Step.DerivedValue ->
            Format.derivedValue

        Step.NullAttribute ->
            Format.null

        Step.BoolAttribute value ->
            Format.bool value

        Step.IntAttribute value ->
            Format.int value

        Step.FloatAttribute value ->
            Format.float value

        Step.StringAttribute value ->
            Format.string value

        Step.BinaryDataAttribute value ->
            Format.binaryData (Bytes.Encode.bytes value)

        Step.EnumAttribute value ->
            Format.enum value

        Step.ReferenceTo _ ->
            "#"

        Step.TypedAttribute typeName nestedAttribute ->
            Format.typedAttribute typeName (attributeString nestedAttribute)

        Step.AttributeList attributes ->
            Format.list (List.map attributeString attributes)


referencedEntities : Step.Attribute -> List Step.Entity
referencedEntities attribute =
    case attribute of
        Step.ReferenceTo entity ->
            [ entity ]

        Step.AttributeList attributes ->
            List.concatMap referencedEntities attributes

        _ ->
            []


childEntities : Step.Entity -> List Step.Entity
childEntities parentEntity =
    case parentEntity of
        Step.SimpleEntity _ attributes ->
            List.concatMap referencedEntities attributes

        Step.ComplexEntity entityRecords ->
            List.concatMap (Tuple.second >> List.concatMap referencedEntities) entityRecords


toggleChildren : DisplayedEntity -> DisplayedEntity
toggleChildren displayedEntity =
    case displayedEntity of
        DisplayedEntity parentEntity [] ->
            DisplayedEntity parentEntity (List.map unexpanded (childEntities parentEntity))

        DisplayedEntity parentEntity _ ->
            DisplayedEntity parentEntity []


viewEntityList : List DisplayedEntity -> List (Html (List DisplayedEntity))
viewEntityList entities =
    List.indexedMap
        (\index entity ->
            viewEntity entity
                |> Html.map
                    (\updatedEntity ->
                        List.Extra.setAt index updatedEntity entities
                    )
        )
        entities


viewEntity : DisplayedEntity -> Html DisplayedEntity
viewEntity ((DisplayedEntity parentEntity currentChildren) as displayedEntity) =
    case currentChildren of
        [] ->
            Html.li [ Html.Events.onClick (toggleChildren displayedEntity) ]
                [ Html.text (entityString parentEntity) ]

        _ ->
            Html.li []
                [ Html.span
                    [ Html.Events.onClick (toggleChildren displayedEntity) ]
                    [ Html.text (entityString parentEntity) ]
                , Html.ul [] (viewEntityList currentChildren)
                    |> Html.map (DisplayedEntity parentEntity)
                ]


viewTopLevelEntity : Int -> DisplayedEntity -> ( String, Html Msg )
viewTopLevelEntity index displayedEntity =
    ( String.fromInt index
    , viewEntity displayedEntity |> Html.map (SetDisplayedEntity index)
    )


view : Model -> Html Msg
view model =
    Html.div []
        [ Html.button [ Html.Events.onClick LoadRequested ] [ Html.text "Load STEP file" ]
        , case model.displayedEntities of
            Nothing ->
                Html.text ""

            Just (Ok displayedEntities) ->
                Html.Keyed.ul [] (List.indexedMap viewTopLevelEntity (reveal displayedEntities))

            Just (Err text) ->
                Html.text text
        ]


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , subscriptions = always Sub.none
        , view = view
        }
