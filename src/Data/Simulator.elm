module Data.Simulator exposing (..)

import Array
import Data.CountryProcess as CountryProcess
import Data.Inputs exposing (Inputs)
import Data.LifeCycle as LifeCycle exposing (LifeCycle)
import Data.Material as Material exposing (Material)
import Data.Process as Process exposing (Cat1(..))
import Data.Product as Product exposing (Product)
import Data.Step as Step exposing (Step)
import Data.Transport as Transport
import Energy
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Mass exposing (Mass)
import Quantity


type alias Simulator =
    { mass : Mass
    , material : Material
    , product : Product
    , lifeCycle : LifeCycle
    , co2 : Float
    , transport : Transport.Summary
    }


default : Simulator
default =
    { mass = Product.tShirt.mass
    , material = Material.cotton
    , product = Product.tShirt
    , lifeCycle = LifeCycle.default
    , co2 = 0
    , transport = Transport.defaultSummary
    }


decode : Decoder Simulator
decode =
    Decode.map6 Simulator
        (Decode.field "mass" (Decode.map Mass.kilograms Decode.float))
        (Decode.field "material" Material.decode)
        (Decode.field "product" Product.decode)
        (Decode.field "lifeCycle" LifeCycle.decode)
        (Decode.field "co2" Decode.float)
        (Decode.field "transport" Transport.decodeSummary)


encode : Simulator -> Encode.Value
encode v =
    Encode.object
        [ ( "mass", Encode.float (Mass.inKilograms v.mass) )
        , ( "material", Material.encode v.material )
        , ( "product", Product.encode v.product )
        , ( "lifeCycle", LifeCycle.encode v.lifeCycle )
        , ( "co2", Encode.float v.co2 )
        , ( "transport", Transport.encodeSummary v.transport )
        ]


fromInputs : Inputs -> Simulator
fromInputs { mass, material, product, countries } =
    compute
        { default
            | mass = mass
            , material = material
            , product = product
            , lifeCycle =
                default.lifeCycle
                    |> Array.indexedMap
                        (\index step ->
                            { step
                                | country =
                                    countries
                                        |> Array.fromList
                                        |> Array.get index
                                        |> Maybe.withDefault step.country
                            }
                        )
        }


toInputs : Simulator -> Inputs
toInputs { mass, product, material, lifeCycle } =
    { mass = mass
    , product = product
    , material = material
    , countries = lifeCycle |> Array.map .country |> Array.toList
    }


compute : Simulator -> Simulator
compute simulator =
    simulator
        -- Step initialization
        |> initLifeCycleSteps
        -- Ensure end product mass is first applied to the final Distribution step
        |> computeMaterialAndSpinningWaste
        --
        -- WASTE
        --
        -- Compute inital required material mass
        |> computeMakingStepWaste
        -- Compute Knitting/Weawing material waste
        |> computeWeavingKnittingStepWaste
        -- Compute Material&Spinning material waste
        |> computeMaterialStepWaste
        --
        -- CO2 SCORES
        --
        -- Compute Material & Spinning step co2 score
        |> computeMaterialAndSpinningCo2Score
        -- Compute Weaving & Knitting step co2 score
        |> computeWeavingKnittingCo2Score
        -- Compute Ennoblement step co2 score
        |> computeEnnoblementCo2Score
        -- Compute Making step co2 score
        |> computeMakingCo2Score
        --
        -- TRANSPORTS
        --
        -- Compute step transport
        |> computeTransportSummaries
        -- Compute transport summary
        |> computeTransportSummary
        --
        -- FINAL CO2 SCORE
        --
        |> computeFinalCo2Score


initLifeCycleSteps : Simulator -> Simulator
initLifeCycleSteps =
    updateLifeCycle LifeCycle.processStepCountries


computeMaterialAndSpinningWaste : Simulator -> Simulator
computeMaterialAndSpinningWaste ({ mass } as simulator) =
    simulator
        |> updateLifeCycleStep
            Step.Distribution
            (\step -> { step | mass = mass })


computeMakingCo2Score : Simulator -> Simulator
computeMakingCo2Score ({ product } as simulator) =
    simulator
        |> updateLifeCycleStep Step.Making
            (\step ->
                let
                    makingCo2 =
                        Process.findByUuid product.makingProcessUuid
                            |> .climateChange
                            |> (*) (Mass.inKilograms step.mass)

                    electricity =
                        Process.findByUuid product.makingProcessUuid
                            |> .elec
                            |> Quantity.multiplyBy (Mass.inKilograms step.mass)

                    elecCo2 =
                        CountryProcess.get step.country
                            |> Maybe.map (.electricity >> .climateChange)
                            |> Maybe.withDefault 0
                            |> (*) (Energy.inKilowattHours electricity)
                in
                { step | co2 = makingCo2 + elecCo2, kwh = electricity }
            )


computeEnnoblementCo2Score : Simulator -> Simulator
computeEnnoblementCo2Score =
    updateLifeCycleStep Step.Ennoblement
        (\step ->
            let
                processes =
                    CountryProcess.get step.country

                dyeingProcess =
                    processes |> Maybe.map .dyeing

                dyeingCo2 =
                    dyeingProcess
                        |> Maybe.map .climateChange
                        |> Maybe.withDefault 0
                        |> (*) (Mass.inKilograms step.mass)

                heatMJ =
                    dyeingProcess
                        |> Maybe.map .heat
                        |> Maybe.withDefault (Energy.megajoules 0)
                        |> Quantity.multiplyBy (Mass.inKilograms step.mass)

                heatCo2 =
                    processes
                        |> Maybe.map (.heat >> .climateChange)
                        |> Maybe.withDefault 0
                        |> (*) (Energy.inMegajoules heatMJ)

                electricity =
                    dyeingProcess
                        |> Maybe.map .elec
                        |> Maybe.withDefault (Energy.megajoules 0)
                        |> Quantity.multiplyBy (Mass.inKilograms step.mass)

                elecCo2 =
                    processes
                        |> Maybe.map (.electricity >> .climateChange)
                        |> Maybe.withDefault 0
                        |> (*) (Energy.inKilowattHours electricity)
            in
            { step
                | co2 = dyeingCo2 + heatCo2 + elecCo2
                , heat = heatMJ
                , kwh = electricity
            }
        )


computeMaterialAndSpinningCo2Score : Simulator -> Simulator
computeMaterialAndSpinningCo2Score ({ material } as simulator) =
    let
        climateChange =
            Process.findByUuid material.materialProcessUuid |> .climateChange
    in
    simulator
        |> updateLifeCycleStep Step.MaterialAndSpinning
            (\step -> { step | co2 = climateChange * Mass.inKilograms step.mass })


computeWeavingKnittingCo2Score : Simulator -> Simulator
computeWeavingKnittingCo2Score ({ product } as simulator) =
    simulator
        |> updateLifeCycleStep Step.WeavingKnitting
            (\step ->
                let
                    previousStepMass =
                        simulator.lifeCycle
                            |> LifeCycle.getStep Step.Ennoblement
                            |> Maybe.map .mass
                            |> Maybe.withDefault (Mass.kilograms 0)

                    -- Note: weaving and knitting processes are the same across all
                    -- countries and are defined by product
                    weavingKnittingProcess =
                        Product.getWeavingKnittingProcess product

                    electricityKWh =
                        -- NOTE: knitted elec is computed against previous step mass,
                        -- weaved elec is computed against current step mass
                        if product.knitted then
                            Mass.inKilograms previousStepMass * Energy.inKilowattHours weavingKnittingProcess.elec

                        else
                            (Mass.inKilograms step.mass * 1000 * toFloat product.ppm / toFloat product.grammage)
                                * weavingKnittingProcess.elec_pppm

                    climateChangeKgCo2e =
                        CountryProcess.get step.country
                            |> Maybe.map (.electricity >> .climateChange)
                            |> Maybe.withDefault 0
                in
                { step
                    | co2 = electricityKWh * climateChangeKgCo2e
                    , kwh = Energy.kilowattHours electricityKWh
                }
            )


computeMakingStepWaste : Simulator -> Simulator
computeMakingStepWaste ({ mass, product } as simulator) =
    let
        confectionWaste =
            Process.findByUuid product.makingProcessUuid |> .waste

        stepMass =
            -- (product weight + textile waste for confection) / (1 - PCR waste rate)
            Mass.kilograms <|
                (Mass.inKilograms mass + (Mass.inKilograms mass * Mass.inKilograms confectionWaste))
                    / (1 - product.pcrWaste)

        stepWaste =
            Quantity.minus mass stepMass
    in
    simulator
        |> updateLifeCycleStep Step.Making (\step -> { step | waste = stepWaste, mass = stepMass })
        |> updateLifeCycleSteps
            [ Step.MaterialAndSpinning, Step.WeavingKnitting, Step.Ennoblement ]
            (\step -> { step | mass = stepMass })


computeWeavingKnittingStepWaste : Simulator -> Simulator
computeWeavingKnittingStepWaste ({ product } as simulator) =
    let
        baseMass =
            simulator.lifeCycle
                |> LifeCycle.getStep Step.Making
                |> Maybe.map .mass
                |> Maybe.withDefault (Mass.kilograms 0)

        weavingKnittingWaste =
            product
                |> Product.getWeavingKnittingProcess
                |> .waste
                |> Quantity.multiplyBy (Mass.inKilograms baseMass)

        stepMass =
            Quantity.plus baseMass weavingKnittingWaste
    in
    simulator
        |> updateLifeCycleStep Step.WeavingKnitting (\step -> { step | mass = stepMass, waste = weavingKnittingWaste })
        |> updateLifeCycleSteps [ Step.MaterialAndSpinning ] (\step -> { step | mass = stepMass })


computeMaterialStepWaste : Simulator -> Simulator
computeMaterialStepWaste ({ material } as simulator) =
    let
        baseMass =
            simulator.lifeCycle
                |> LifeCycle.getStep Step.WeavingKnitting
                |> Maybe.map .mass
                |> Maybe.withDefault (Mass.kilograms 0)

        stepWaste =
            Process.findByUuid material.materialProcessUuid
                |> .waste
                |> Quantity.multiplyBy (Mass.inKilograms baseMass)

        stepMass =
            Quantity.plus baseMass stepWaste
    in
    simulator
        |> updateLifeCycleStep Step.MaterialAndSpinning
            (\step -> { step | mass = stepMass, waste = stepWaste })


computeTransportSummaries : Simulator -> Simulator
computeTransportSummaries =
    updateLifeCycle LifeCycle.computeTransportSummaries


computeTransportSummary : Simulator -> Simulator
computeTransportSummary simulator =
    { simulator | transport = simulator.lifeCycle |> LifeCycle.computeTransportSummary }


computeFinalCo2Score : Simulator -> Simulator
computeFinalCo2Score simulator =
    { simulator | co2 = LifeCycle.computeFinalCo2Score simulator.lifeCycle }


updateLifeCycle : (LifeCycle -> LifeCycle) -> Simulator -> Simulator
updateLifeCycle update simulator =
    { simulator | lifeCycle = update simulator.lifeCycle }


updateLifeCycleStep : Step.Label -> (Step -> Step) -> Simulator -> Simulator
updateLifeCycleStep label update =
    updateLifeCycle (LifeCycle.updateStep label update)


updateLifeCycleSteps : List Step.Label -> (Step -> Step) -> Simulator -> Simulator
updateLifeCycleSteps labels update =
    updateLifeCycle (LifeCycle.updateSteps labels update)
