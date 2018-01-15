{-# LANGUAGE OverloadedStrings, ViewPatterns, ScopedTypeVariables, QuasiQuotes, FlexibleContexts #-}
module EU4.Common (
        pp_script
    ,   pp_mtth
    ,   ppOne
    ,   ppMany
    ,   iconKey, iconFile, iconFileB
    ,   AIWillDo (..), AIModifier (..)
    ,   ppAiWillDo, ppAiMod
    ,   module EU4.Types
    ) where

import Debug.Trace (trace, traceM)
import Yaml (LocEntry (..))

import Control.Applicative (liftA2)
import Control.Arrow (first)
import Control.Monad (liftM, MonadPlus (..), forM, foldM, join {- temp -}, when)
import Control.Monad.Reader (MonadReader (..), asks)
import Control.Monad.State (MonadState (..), gets)

import Data.Char (isUpper, toUpper, toLower)
import Data.List (foldl', intersperse)
import Data.Maybe (isJust, fromMaybe, listToMaybe)
import Data.Monoid ((<>))
import Data.Foldable (fold)

import Data.ByteString (ByteString)

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Encoding as TE

-- TODO: get rid of these, do icon key lookups from another module
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Trie (Trie)
import qualified Data.Trie as Tr

import qualified Data.Set as S

import Text.PrettyPrint.Leijen.Text (Doc)
import qualified Text.PrettyPrint.Leijen.Text as PP

import Abstract -- everything
import qualified Doc
import Messages -- everything
import MessageTools (plural)
import QQ (pdx)
import SettingsTypes ( PPT, Settings (..), GameState (..)
                     , Game (..), IsGame (..), IsGameData (..), IsGameState (..)
                     , getGameL10n, getGameL10nIfPresent, getGameL10nDefault
                     , indentUp, indentDown, alsoIndent', withCurrentIndent, withCurrentIndentZero
                     , unfoldM)
import EU4.Types -- everything

isGeographic :: EU4Scope -> Bool
isGeographic EU4Country = False
isGeographic EU4Province = True
isGeographic EU4TradeNode = True
isGeographic EU4Geographic = True
isGeographic EU4Bonus = False

-- no particular order from here... TODO: organize this!

msgToPP :: (IsGameState (GameState g), Monad m) => ScriptMessage -> PPT g m IndentedMessages
msgToPP msg = (:[]) <$> alsoIndent' msg

isTag :: Text -> Bool
isTag s = T.length s == 3 && T.all isUpper s

isPronoun :: Text -> Bool
isPronoun s = T.map toLower s `S.member` pronouns where
    pronouns = S.fromList
        ["本国"
        ,"前者"
        ,"所有者"
        ,"控制者"
        ]

pp_script :: (EU4Info g, Monad m) =>
    GenericScript -> PPT g m Doc
pp_script [] = return "没有效果"
pp_script script = imsg2doc =<< ppMany script

-- Get the localization for a province ID, if available.
getProvLoc :: (IsGameData (GameData g), Monad m) =>
    Int -> PPT g m Text
getProvLoc n =
    let provid_t = T.pack (show n)
    in getGameL10nDefault provid_t ("PROV" <> provid_t)


-- Emit flag template if the argument is a tag.
flag :: (IsGameData (GameData g), Monad m) => Text -> PPT g m Doc
flag name =
    if isTag name
        then template "flag" . (:[]) <$> getGameL10n name
        else return $ case T.map toUpper name of
                "ROOT" -> "我国" -- will need editing for capitalization in some cases
                "PREV" -> "前者"
                -- Suggestions of a description for FROM are welcome.
                _ -> Doc.strictText name

flagText :: (IsGameData (GameData g),
             IsGameState (GameState g),
             Monad m) =>
    Text -> PPT g m Text
flagText = fmap Doc.doc2text . flag

-- Emit icon template.
icon :: Text -> Doc
icon what = template "icon" [HM.lookupDefault what what scriptIconTable, "28px"]
iconText :: Text -> Text
iconText = Doc.doc2text . icon

plainMsg :: (IsGameState (GameState g), Monad m) => Text -> PPT g m IndentedMessages
plainMsg msg = (:[]) <$> (alsoIndent' . MsgUnprocessed $ msg)

-- Surround a doc in a <pre> element.
pre_statement :: GenericStatement -> Doc
pre_statement stmt = "<pre>" <> genericStatement2doc stmt <> "</pre>"

-- Don't use Doc.doc2text, because it uses renderCompact which is not what we want
-- here.
preMessage :: GenericStatement -> ScriptMessage
preMessage = MsgUnprocessed
            . TL.toStrict
            . PP.displayT
            . PP.renderPretty 0.8 80
            . pre_statement

preStatement :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
preStatement stmt = (:[]) <$> alsoIndent' (preMessage stmt)

-- Text version
pre_statement' :: GenericStatement -> Text
pre_statement' = Doc.doc2text . pre_statement

ppMany :: (EU4Info g, Monad m) => GenericScript -> PPT g m IndentedMessages
ppMany scr = indentUp (concat <$> mapM ppOne scr)

-- Table of handlers for statements.
-- Dispatch on strings is /much/ quicker using a lookup table than a
-- huge case statement, which uses (==) on each one in turn.
ppHandlers :: (EU4Info g, Monad m) =>
    Trie (GenericStatement -> PPT g m IndentedMessages)
ppHandlers = Tr.fromList
        -- Statements where RHS is irrelevant (usually "yes")
        [("add_cardinal"           , const (msgToPP MsgAddCardinal))
        ,("cancel_construction"    , const (msgToPP MsgCancelConstruction)) -- Canals
        ,("cb_on_overseas"         , const (msgToPP MsgGainOverseasCB)) -- Full Expansion
        ,("cb_on_primitives"       , const (msgToPP MsgGainPrimitivesCB)) -- Full Exploration
        ,("cb_on_religious_enemies", const (msgToPP MsgGainReligiousCB)) -- Deus Vult
        ,("enable_hre_leagues"     , const (msgToPP MsgEnableHRELeagues))
        ,("kill_heir"              , const (msgToPP MsgHeirDies))
        ,("kill_ruler"             , const (msgToPP MsgRulerDies))
        ,("may_agitate_for_liberty", const (msgToPP MsgMayAgitateForLiberty)) -- Espionage: Destabilizing Efforts
        ,("may_explore"            , const (msgToPP MsgMayExplore)) -- Exploration: Quest for the New World
        ,("may_infiltrate_administration", const (msgToPP MsgMayInfiltrateAdministration)) -- Espionage: Espionage
        ,("may_sabotage_reputation", const (msgToPP MsgMaySabotageReputation)) -- Espionage: Rumormongering
        ,("may_sow_discontent"     , const (msgToPP MsgMaySowDiscontent)) -- Espionage: Destabilizing Efforts
        ,("may_study_technology"   , const (msgToPP MsgMayStudyTech)) -- Espionage: Shady Recruitment
        ,("set_hre_religion_treaty", const (msgToPP MsgSignWestphalia))
        ,("reduced_stab_impacts"   , const (msgToPP MsgReducedStabImpacts)) -- Full Diplomacy
        ,("remove_cardinal"        , const (msgToPP MsgLoseCardinal))
        ,("sea_repair"             , const (msgToPP MsgGainSeaRepair)) -- Full Maritime
        -- Some new features added by Pokewiz
        ,("is_vassal"                    , withBool MsgIsVassal)
        ,("is_march"                     , withBool MsgIsMarch)
        ,("is_rival"                     , withBool MsgIsRival)
        ,("is_empty"                     , withBool MsgIsEmpty)
        ,("is_owned_by_trade_company"    , withBool MsgIsOwnedByTradeCompany)
        ,("is_free_or_tributary_trigger" , withBool MsgIsFreeOrTributaryTrigger)
        ,("set_papacy_active"            , withBool MsgSetPapacyActive)
        ,("has_new_dynasty"              , withBool MsgHasNewDynasty)
        ,("add_stability_or_adm_power"   , withBool MsgAddStabilityOrADMPower)
        ,("uses_religious_icons"         , withBool MsgUsesReligiousIcons)
        ,("trade_company_size"           , numeric MsgTradeCompanySize)
        ,("native_hostileness"           , numericIcon "aggressiveness" MsgNativeHostileness)
        ,("change_native_hostileness"    , numericIcon "aggressiveness" MsgGaineNativeHostileness)
        ,("native_ferocity"              , numericIcon "ferocity" MsgNativeFerocity)
        ,("change_native_ferocity"       , numericIcon "ferocity" MsgGainNativeFerocity)
        ,("native_size"                  , numeric MsgNativeSize)
        ,("change_native_size"           , numeric MsgGainNativeSize)
        ,("add_colonysize"               , numericIcon "global settler increase" MsgGainColonySize)
        ,("discover_province"            , withProvince MsgDiscoverProvince)
        ,("corruption"                   , numericIcon "corruption" MsgCorruption)
        ,("add_corruption"               , numericIcon "corruption" MsgGainCorruption)
        ,("yearly_corruption_increase"   , numericIcon "corruption" MsgYearlyCorruptionIncrease)
        ,("has_institution"              , withLocAtomIcon MsgHasInstitution)
        ,("has_consort"                  , withBool MsgHasConsort)
        ,("has_empty_adjacent_province"  , withBool MsgHasEmptyAdjacentProvince)
        ,("is_state"                     , withBool MsgIsState)
        ,("is_heir_leader"               , withBool MsgIsHeirLeader)
        ,("is_in_coalition"              , withBool MsgIsinCoalition)
        ,("is_emperor_of_china"          , withBool MsgIsEmperorOfChina)
        ,("has_owner_accepted_culture"   , withBool MsgHasOwnerAcceptedCulture)
        ,("has_active_debate"            , withBool MsgHasActiveDebate)
        ,("is_backing_current_issue"     , withBool MsgIsBackingCurrentIssue)
        ,("is_in_capital_area"           , withBool MsgIsInCapitalArea)
        ,("add_mandate_effect"           , withBool MsgAddMandateEffect)
        ,("reduce_mandate_effect"        , withBool MsgReduceMandateEffect)
        ,("add_meritocracy_effect"       , withBool MsgAddMeritocracyEffect)
        ,("reduce_meritocracy_effect"    , withBool MsgReduceMeritocracyEffect)
        -- Numbers
        ,("add_authority"                    , numeric MsgGainAuth) -- Inti
        ,("add_doom"                         , numeric MsgGainDoom)
        ,("add_heir_claim"                   , numeric MsgHeirGainClaim)
        ,("change_siege"                     , numeric MsgGainSiegeProgress)
        ,("colonysize"                       , numeric MsgColonySettlers)
        ,("had_recent_war"                   , numeric MsgWasAtWar)
        ,("heir_age"                         , numeric MsgHeirAge)
        ,("is_year"                          , numeric MsgYearIs)
        ,("num_of_colonial_subjects"         , numeric MsgNumColonialSubjects)
        ,("num_of_colonies"                  , numeric MsgNumColonies)
        ,("num_of_loans"                     , numeric MsgNumLoans)
        ,("num_of_mercenaries"               , numeric MsgNumMercs)
        ,("num_of_ports"                     , numeric MsgNumPorts) -- same as num_of_total_ports?
        ,("num_of_rebel_armies"              , numeric MsgNumRebelArmies)
        ,("num_of_rebel_controlled_provinces", numeric MsgNumRebelControlledProvinces)
        ,("num_of_total_ports"               , numeric MsgNumPorts) -- same as num_of_ports?
        ,("num_of_trade_embargos"            , numeric MsgNumEmbargoes)
        ,("revolt_percentage"                , numeric MsgRevoltPercentage)
        ,("trade_income_percentage"          , numeric MsgTradeIncomePercentage)
        ,("units_in_province"                , numeric MsgUnitsInProvince)
        -- ... with icons
        ,("add_adm_power"            , numericIcon "adm" MsgGainADM)
        ,("add_army_tradition"       , numericIcon "army tradition" MsgGainAT)
        ,("add_base_manpower"        , numericIcon "manpower" MsgGainBM)
        ,("add_base_production"      , numericIcon "production" MsgGainBP)
        ,("add_base_tax"             , numericIcon "base tax" MsgGainBT)
        ,("add_church_power"         , numericIcon "church power" MsgGainChurchPower)
        ,("add_devotion"             , numericIcon "devotion" MsgGainDevotion)
        ,("add_dip_power"            , numericIcon "dip" MsgGainDIP)
        ,("add_fervor"               , numericIcon "monthly fervor" MsgGainFervor)
        ,("add_horde_unity"          , numericIcon "horde unity" MsgGainHordeUnity)
        ,("add_imperial_influence"   , numericIcon "imperial authority" MsgGainImperialAuthority)
        ,("add_inflation"            , numericIcon "inflation" MsgGainInflation)
        ,("add_karma"                , numericIcon "high karma" MsgGainKarma)
        ,("add_legitimacy"           , numericIcon "legitimacy" MsgGainLegitimacy)
        ,("add_liberty_desire"       , numericIcon "liberty desire" MsgGainLibertyDesire)
        ,("add_local_autonomy"       , numericIcon "local autonomy" MsgGainLocalAutonomy)
        ,("add_mercantilism"         , numericIcon "mercantilism" MsgGainMercantilism)
        ,("add_mil_power"            , numericIcon "mil" MsgGainMIL)
        ,("add_navy_tradition"       , numericIcon "navy tradition" MsgGainNavyTradition)
        ,("add_papal_influence"      , numericIcon "papal influence" MsgGainPapalInfluence)
        ,("add_patriarch_authority"  , numericIcon "patriarch authority" MsgGainPatAuth)
        ,("add_piety"                , numericIcon "piety" MsgGainPiety)
        ,("add_prestige"             , numericIcon "prestige" MsgGainPrestige)
        ,("add_reform_desire"        , numericIcon "reform desire" MsgGainReformDesire)
        ,("add_republican_tradition" , numericIcon "republican tradition" MsgGainRepTrad)
        ,("add_stability"            , numericIcon "stability" MsgGainStability)
        ,("add_treasury"             , numericIcon "ducats" MsgAddTreasury)
        ,("add_unrest"               , numericIcon "local unrest" MsgAddLocalUnrest)
        ,("add_war_exhaustion"       , numericIcon "war exhaustion" MsgGainWarExhaustion)
        ,("add_yearly_manpower"      , numericIcon "manpower" MsgGainYearlyManpower)
        ,("add_years_of_income"      , numericIcon "ducats" MsgAddYearsOfIncome)
        ,("adm"                      , numericIcon "adm" MsgRulerADM)
        ,("adm_power"                , numericIcon "adm" MsgHasADM)
        ,("adm_tech"                 , numericIcon "adm tech" MsgADMTech)
        ,("army_reformer"            , numericIcon "army reformer" MsgHasArmyReformerLevel)
        ,("army_tradition"           , numericIconBonus "army tradition" MsgArmyTradition MsgYearlyArmyTradition)
        ,("artist"                   , numericIcon "artist" MsgHasArtistLevel)
        ,("base_manpower"            , numericIcon "manpower" MsgBaseManpower)
        ,("base_production"          , numericIcon "base production" MsgBaseProduction)
        ,("base_tax"                 , numericIcon "base tax" MsgBaseTax)
        ,("blockade"                 , numericIcon "blockade" MsgBlockade)
        ,("change_adm"               , numericIcon "adm" MsgGainADMSkill)
        ,("change_dip"               , numericIcon "dip" MsgGainDIPSkill)
        ,("change_mil"               , numericIcon "mil" MsgGainMILSkill)
        ,("create_admiral"           , numericIcon "admiral" MsgCreateAdmiral)
        ,("create_conquistador"      , numericIcon "conquistador" MsgCreateConquistador)
        ,("create_explorer"          , numericIcon "explorer" MsgCreateExplorer)
        ,("create_general"           , numericIcon "general" MsgCreateGeneral)
        ,("development"              , numericIcon "development" MsgDevelopment)
        ,("dip"                      , numericIcon "dip" MsgRulerDIP)
        ,("dip_power"                , numericIcon "adm" MsgHasDIP)
        ,("dip_tech"                 , numericIcon "dip tech" MsgDIPTech)
        ,("diplomat"                 , numericIcon "diplomat" MsgHasDiplomatLevel)
        ,("fort_level"               , numericIcon "fort level" MsgFortLevel)
        ,("gold_income_percentage"   , numericIcon "gold" MsgGoldIncomePercentage)
        ,("horde_unity"              , numericIconBonus "horde unity" MsgHordeUnity MsgYearlyHordeUnity)
        ,("imperial_influence"       , numericIcon "imperial authority" MsgImperialAuthority)
        ,("inflation"                , numericIcon "inflation" MsgInflation)
        ,("karma"                    , numericIcon "high karma" MsgKarma)
        ,("legitimacy"               , numericIconBonus "legitimacy" MsgLegitimacy MsgYearlyLegitimacy)
        ,("liberty_desire"           , numericIcon "liberty desire" MsgLibertyDesire)
        ,("local_autonomy"           , numericIcon "local autonomy" MsgLocalAutonomy)
        ,("manpower_percentage"      , numericIcon "manpower" MsgManpowerPercentage)
        ,("mercantilism"             , numericIcon "mercantilism" MsgMercantilism)
        ,("mil"                      , numericIcon "mil" MsgRulerMIL)
        ,("mil_power"                , numericIcon "adm" MsgHasMIL)
        ,("mil_tech"                 , numericIcon "mil tech" MsgMILTech)
        ,("monthly_income"           , numericIcon "ducats" MsgMonthlyIncome)
        ,("nationalism"              , numericIcon "years of separatism" MsgSeparatism)
        ,("natural_scientist"        , numericIcon "natural scientist" MsgHasNaturalScientistLevel)
        ,("naval_forcelimit"         , numericIcon "naval force limit" MsgNavalForcelimit)
        ,("naval_reformer"           , numericIcon "naval reformer" MsgHasNavyReformerLevel)
        ,("navy_tradition"           , numericIconBonus "navy tradition" MsgNavyTradition MsgYearlyNavyTradition)
        ,("navy_reformer"            , numericIcon "naval reformer" MsgHasNavyReformerLevel) -- both are used
        ,("navy_size_percentage"     , numericIcon "naval force limit" MsgNavyPercentage)
        ,("num_of_allies"            , numericIcon "alliance" MsgNumAllies)
        ,("num_of_cardinals"         , numericIcon "cardinal" MsgNumCardinals)
        ,("num_of_colonists"         , numericIcon "colonists" MsgNumColonists)
        ,("num_of_heavy_ship"        , numericIcon "heavy ship" MsgNumHeavyShips)
        ,("num_of_light_ship"        , numericIcon "light ship" MsgNumLightShips)
        ,("num_of_merchants"         , numericIcon "merchant" MsgNumMerchants)
        ,("num_of_missionaries"      , numericIcon "missionary" MsgNumMissionaries)
        ,("num_of_royal_marriages"   , numericIcon "royal marriage" MsgNumRoyalMarriages)
        ,("num_of_unions"            , numericIcon "personal union" MsgNumUnions)
        ,("num_of_vassals"           , numericIcon "vassal" MsgNumVassals) -- includes other subjects?
        ,("overextension_percentage" , numericIcon "overextension" MsgOverextension)
        ,("reform_desire"            , numericIcon "reform desire" MsgReformDesire)
        ,("religious_unity"          , numericIconBonus "religious unity" MsgReligiousUnity MsgReligiousUnityBonus)
        ,("republican_tradition"     , numericIconBonus "republican tradition" MsgRepTrad MsgYearlyRepTrad)
        ,("stability"                , numericIcon "stability" MsgStability)
        ,("statesman"                , numericIcon "statesman" MsgHasStatesmanLevel)
        ,("theologian"               , numericIcon "theologian" MsgHasTheologianLevel)
        ,("total_development"        , numericIcon "development" MsgTotalDevelopment)
        ,("total_number_of_cardinals", numericIcon "cardinal" MsgTotalCardinals) -- in the world
        ,("trade_efficiency"         , numericIconBonus "trade efficiency" MsgTradeEfficiency MsgTradeEfficiencyBonus)
        ,("trader"                   , numericIcon "trader" MsgHasTraderLevel)
        ,("treasury"                 , numericIcon "ducats" MsgHasDucats)
        ,("unrest"                   , numericIcon "unrest" MsgUnrest)
        ,("war_exhaustion"           , numericIconBonus "war exhaustion" MsgWarExhaustion MsgMonthlyWarExhaustion)
        ,("war_score"                , numericIcon "war score" MsgWarScore)
        ,("years_of_income"          , numericIcon "ducats" MsgYearsOfIncome)
        -- Used in ideas and other bonuses, omit "gain/lose" in l10n
        ,("accepted_culture_threshold"        , numericIcon "accepted culture threshold" MsgAccCultureThreshold)
        ,("adm_tech_cost_modifier"            , numericIcon "adm tech cost modifier" MsgADMTechCost)
        ,("advisor_cost"                      , numericIcon "advisor cost" MsgAdvisorCost)
        ,("advisor_pool"                      , numericIcon "advisor pool" MsgPossibleAdvisors)
        ,("ae_impact"                         , numericIcon "ae impact" MsgAEImpact)
        ,("army_tradition_decay"              , numericIcon "army tradition decay" MsgArmyTraditionDecay)
        ,("artillery_power"                   , numericIcon "artillery power" MsgArtilleryCombatAbility)
        ,("blockade_efficiency"               , numericIcon "blockade efficiency" MsgBlockadeEfficiency)
        ,("build_cost"                        , numericIcon "build cost" MsgBuildCost)
        ,("caravan_power"                     , numericIcon "caravan power" MsgCaravanPower)
        ,("cavalry_cost"                      , numericIcon "cavalry cost" MsgCavalryCost)
        ,("cavalry_power"                     , numericIcon "cavalry power" MsgCavalryCombatAbility)
        ,("church_power_modifier"             , numericIcon "church power" MsgChurchPowerModifier)
        ,("colonists"                         , numericIcon "colonists" MsgColonists)
        ,("core_creation"                     , numericIcon "core creation cost" MsgCoreCreationCost)
        ,("culture_conversion_cost"           , numericIcon "culture conversion cost" MsgCultureConvCost)
        ,("defensiveness"                     , numericIcon "defensiveness" MsgFortDefense)
        ,("development_cost"                  , numericIcon "development cost" MsgDevelCost)
        ,("devotion"                          , numericIcon "devotion" MsgYearlyDevotion)
        ,("diplomatic_annexation_cost"        , numericIcon "diplomatic annexation cost" MsgDiploAnnexCost)
        ,("diplomatic_reputation"             , numericIcon "diplomatic reputation" MsgDiploRep)
        ,("diplomatic_upkeep"                 , numericIcon "diplomatic upkeep" MsgDiploRelations)
        ,("diplomats"                         , numericIcon "diplomats" MsgDiplomats)
        ,("dip_tech_cost_modifier"            , numericIcon "dip tech cost modifier" MsgDIPTechCost)
        ,("discipline"                        , numericIcon "discipline" MsgDiscipline)
        ,("discovered_relations_impact"       , numericIcon "discovered relations impact" MsgCovertActionRelationImpact)
        ,("embargo_efficiency"                , numericIcon "embargo efficiency" MsgEmbargoEff)
        ,("enemy_core_creation"               , numericIcon "enemy core creation" MsgHostileCoreCreation)
        ,("envoy_travel_time"                 , numericIcon "envoy travel time" MsgEnvoyTravelTime)
        ,("fabricate_claims_time"             , numericIcon "time to fabricate claims" MsgTimeToFabricateClaims)
        ,("fort_maintenance_modifier"         , numericIcon "fort maintenance" MsgFortMaintenance)
        ,("free_leader_pool"                  , numericIcon "free leader pool" MsgLeadersWithoutUpkeep)
        ,("galley_power"                      , numericIcon "galley power" MsgGalleyCombatAbility)
        ,("garrison_size"                     , numericIcon "garrison size" MsgGarrisonSize)
        ,("global_autonomy"                   , numericIcon "global autonomy" MsgGlobalAutonomy)
        ,("global_colonial_growth"            , numericIcon "global settler increase" MsgGlobalSettlers)
        ,("global_heretic_missionary_strength", numericIcon "global heretic missionary strength" MsgMissionaryStrengthVsHeretics)
        ,("global_manpower_modifier"          , numericIcon "national manpower modifier" MsgNationalManpowerMod)
        ,("global_missionary_strength"        , numericIcon "missionary strength" MsgMissionaryStrength)
        ,("global_regiment_cost"              , numericIcon "regiment cost" MsgRegimentCost)
        ,("global_regiment_recruit_speed" {-sic-}, numericIcon "global regiment recruit speed" MsgRecruitmentTime)
        ,("global_ship_cost"                  , numericIcon "ship cost" MsgGlobalShipCost)
        ,("global_ship_recruit_speed" {- sic -}, numericIcon "shipbuilding time" MsgShipbuildingTime)
        ,("global_ship_repair"                , numericIcon "global ship repair" MsgGlobalShipRepair)
        ,("global_spy_defence"                , numericIcon "global spy defence" MsgGlobalSpyDefence)
        ,("global_tariffs"                    , numericIcon "global tariffs" MsgGlobalTariffs)
        ,("global_tax_modifier"               , numericIcon "global tax modifier" MsgGlobalTaxModifier)
        ,("global_trade_goods_size_modifier"  , numericIcon "goods produced modifier" MsgGoodsProducedMod)
        ,("global_trade_power"                , numericIcon "global trade power" MsgGlobalTradePower)
        ,("global_unrest"                     , numericIcon "national unrest" MsgNationalUnrest)
        ,("heavy_ship_power"                  , numericIcon "heavy ship power" MsgHeavyShipCombatAbility)
        ,("hostile_attrition"                 , numericIcon "attrition for enemies" MsgAttritionForEnemies)
        ,("idea_cost"                         , numericIcon "idea cost" MsgIdeaCost)
        ,("improve_relation_modifier"         , numericIcon "improve relations" MsgImproveRelations)
        ,("infantry_cost"                     , numericIcon "infantry cost" MsgInfantryCost)
        ,("infantry_power"                    , numericIcon "infantry power" MsgInfantryCombatAbility)
        ,("inflation_action_cost"             , numericIcon "reduce inflation cost" MsgReduceInflationCost)
        ,("inflation_reduction"               , numericIcon "inflation reduction" MsgYearlyInflationReduction)
        ,("interest"                          , numericIcon "interest" MsgInterestPerAnnum)
        ,("land_maintenance_modifier"         , numericIcon "land maintenance" MsgLandMaintenanceMod)
        ,("land_morale"                       , numericIcon "morale of armies" MsgMoraleOfArmies)
        ,("land_attrition"                    , numericIcon "land attrition" MsgLandAttrition)
        ,("land_forcelimit_modifier"          , numericIcon "land forcelimit modifier" MsgLandForcelimitMod)
        ,("leader_land_fire"                  , numericIcon "land leader fire" MsgLandLeaderFire)
        ,("leader_land_shock"                 , numericIcon "land leader shock" MsgLandLeaderShock)
        ,("leader_land_manuever" {- sic -}    , numericIcon "land leader maneuver" MsgLandLeaderManeuver)
        ,("leader_land_siege"                 , numericIcon "leader siege" MsgLeaderSiege)
        ,("leader_naval_fire"                 , numericIcon "naval leader fire" MsgNavalLeaderFire)
        ,("leader_naval_manuever" {- sic -}   , numericIcon "naval leader maneuver" MsgNavalLeaderManeuver)
        ,("leader_naval_shock"                , numericIcon "naval leader shock" MsgNavalLeaderShock)
        ,("light_ship_power"                  , numericIcon "light ship power" MsgLightShipCombatAbility)
        ,("manpower_recovery_speed"           , numericIcon "manpower recovery speed" MsgManpowerRecoverySpeed)
        ,("mercenary_cost"                    , numericIcon "mercenary cost" MsgMercCost)
        ,("merc_maintenance_modifier"         , numericIcon "merc maintenance modifier" MsgMercMaintenance)
        ,("merchants"                         , numericIcon "merchants" MsgMerchants)
        ,("mil_tech_cost_modifier"            , numericIcon "adm tech cost modifier" MsgMILTechCost)
        ,("missionaries"                      , numericIcon "missionaries" MsgMissionaries)
        ,("monthly_fervor_increase"           , numericIcon "monthly fervor" MsgMonthlyFervor)
        ,("naval_attrition"                   , numericIcon "naval attrition" MsgNavalAttrition)
        ,("naval_forcelimit_modifier"         , numericIcon "naval forcelimit" MsgNavalForcelimitMod)
        ,("naval_maintenance_modifier"        , numericIcon "naval maintenance" MsgNavalMaintenanceMod)
        ,("naval_morale"                      , numericIcon "morale of navies" MsgMoraleOfNavies)
        ,("navy_tradition"                    , numericIcon "navy tradition" MsgYearlyNavyTradition)
        ,("navy_tradition_decay"              , numericIcon "navy tradition decay" MsgNavyTraditionDecay)
        ,("papal_influence"                   , numericIcon "papal influence" MsgYearlyPapalInfluence)
        ,("possible_mercenaries"              , numericIcon "available mercenaries" MsgAvailableMercs)
        ,("prestige"                          , numericIconBonus "prestige" MsgPrestige MsgYearlyPrestige)
        ,("prestige_decay"                    , numericIcon "prestige decay" MsgPrestigeDecay)
        ,("prestige_from_land"                , numericIcon "prestige from land" MsgPrestigeFromLand)
        ,("prestige_from_naval"               , numericIcon "prestige from naval" MsgPrestigeFromNaval)
        ,("privateer_efficiency"              , numericIcon "privateer efficiency" MsgPrivateerEff)
        ,("production_efficiency"             , numericIcon "production efficiency" MsgProdEff)
        ,("province_warscore_cost"            , numericIcon "province warscore cost" MsgProvinceWarscoreCost)
        ,("rebel_support_efficiency"          , numericIcon "reform desire" MsgRebelSupportEff)
        ,("recover_army_morale_speed"         , numericIcon "recover army morale speed" MsgRecoverArmyMoraleSpeed)
        ,("reinforce_speed"                   , numericIcon "reinforce speed" MsgReinforceSpeed)
        ,("relations_decay_of_me"             , numericIcon "better relations over time" MsgBetterRelationsOverTime)
        ,("ship_durability"                   , numericIcon "ship durability" MsgShipDurability)
        ,("siege_ability"                     , numericIcon "siege ability" MsgSiegeAbility)
        ,("spy_offence"                       , numericIcon "spy offense" MsgSpyOffense) -- US spelling in game
        ,("stability_cost_modifier"           , numericIcon "stability cost" MsgStabilityCost)
        ,("technology_cost"                   , numericIcon "technology cost" MsgTechCost)
        ,("tolerance_heathen"                 , numericIcon "tolerance heathen" MsgToleranceHeathen)
        ,("tolerance_heretic"                 , numericIcon "tolerance heretic" MsgToleranceHeretic)
        ,("tolerance_own"                     , numericIcon "tolerance own" MsgToleranceTrue)
        ,("trade_range_modifier"              , numericIcon "trade range" MsgTradeRange)
        ,("trade_steering"                    , numericIcon "trade steering" MsgTradeSteering)
        ,("unjustified_demands"               , numericIcon "unjustified demands" MsgUnjustifiedDemands)
        ,("vassal_forcelimit_bonus"           , numericIcon "vassal forcelimit bonus" MsgVassalForcelimitContribution)
        ,("vassal_income"                     , numericIcon "income from vassals" MsgIncomeFromVassals)
        ,("war_exhaustion_cost"               , numericIcon "war exhaustion cost" MsgWarExhaustionCost)
        ,("years_of_nationalism"              , numericIcon "years of separatism" MsgYearsOfSeparatism)
        -- Modifiers
        ,("add_country_modifier"           , addModifier MsgCountryMod)
        ,("add_permanent_province_modifier", addModifier MsgPermanentProvMod)
        ,("add_province_modifier"          , addModifier MsgProvMod)
        ,("add_ruler_modifier"             , addModifier MsgRulerMod)
        ,("add_trade_modifier"             , addModifier MsgTradeMod)
        ,("has_country_modifier"           , withLocAtom2 MsgCountryMod MsgHasModifier)
        ,("has_province_modifier"          , withLocAtom2 MsgProvMod MsgHasModifier)
        ,("has_ruler_modifier"             , withLocAtom2 MsgRulerMod MsgHasModifier)
        ,("has_trade_modifier"             , tradeMod)
        ,("remove_country_modifier"        , withLocAtom2 MsgCountryMod MsgRemoveModifier)
        ,("remove_province_modifier"       , withLocAtom2 MsgProvMod MsgRemoveModifier)
        -- Simple compound statements
        -- Note that "any" can mean "all" or "one or more" depending on context.
        ,("and" , compoundMessage MsgAllOf)
        ,("root", compoundMessage MsgOurCountry)
        -- These two are ugly, but without further analysis we can't know
        -- what it means.
        ,("from", compoundMessage MsgFROM)
        ,("prev", compoundMessage MsgPREV)
        ,("not" , compoundMessage MsgNoneOf)
        ,("or"  , compoundMessage MsgAtLeastOneOf)
        -- There is a semantic distinction between "all" and "every",
        -- namely that the former means "this is true for all <type>" while
        -- the latter means "do this for every <type>."
        ,("all_country" {- sic -}   , scope EU4Country   . compoundMessage MsgAllCountries)
        ,("all_owned_province"      , scope EU4Province  . compoundMessage MsgEveryOwnedProvince)
        ,("any_active_trade_node"   , scope EU4TradeNode . compoundMessage MsgAnyActiveTradeNode)
        ,("any_ally"                , scope EU4Country   . compoundMessage MsgAnyAlly)
        ,("any_core_country"        , scope EU4Country   . compoundMessage MsgAnyCoreCountry) -- province scope
        ,("any_country"             , scope EU4Country   . compoundMessage MsgAnyCountry)
        ,("any_enemy_country"       , scope EU4Country   . compoundMessage MsgAnyEnemyCountry)
        ,("any_known_country"       , scope EU4Country   . compoundMessage MsgAnyKnownCountry)
        ,("any_neighbor_country"    , scope EU4Country   . compoundMessage MsgAnyNeighborCountry)
        ,("any_neighbor_province"   , scope EU4Province  . compoundMessage MsgAnyNeighborProvince)
        ,("any_owned_province"      , scope EU4Province  . compoundMessage MsgAnyOwnedProvince)
        ,("any_rival_country"       , scope EU4Country   . compoundMessage MsgAnyRival)
        ,("any_subject_country"     , scope EU4Country   . compoundMessage MsgAnySubject)
        ,("capital_scope"           , scope EU4Province  . compoundMessage MsgCapital)
        ,("colonial_parent"         , scope EU4Country   . compoundMessage MsgColonialParent)
        ,("controller"              , scope EU4Country   . compoundMessage MsgController)
        ,("emperor"                 , scope EU4Country   . compoundMessage MsgEmperor)
        ,("every_country"           , scope EU4Country   . compoundMessage MsgEveryCountry)
        ,("every_enemy_country"     , scope EU4Country   . compoundMessage MsgEveryEnemyCountry)
        ,("every_known_country"     , scope EU4Country   . compoundMessage MsgEveryKnownCountry)
        ,("every_neighbor_country"  , scope EU4Country   . compoundMessage MsgEveryNeighborCountry)
        ,("every_neighbor_province" , scope EU4Province  . compoundMessage MsgEveryNeighborProvince)
        ,("every_owned_province"    , scope EU4Province  . compoundMessage MsgEveryOwnedProvince)
        ,("every_province"          , scope EU4Province  . compoundMessage MsgEveryProvince)
        ,("every_rival_country"     , scope EU4Country   . compoundMessage MsgEveryRival)
        ,("every_subject_country"   , scope EU4Country   . compoundMessage MsgEverySubject)
        ,("hidden_effect"           ,                      compoundMessage MsgHiddenEffect)
        ,("if"                      ,                      compoundMessage MsgIf) -- always needs editing
        ,("limit"                   ,                      compoundMessage MsgLimit) -- always needs editing
        ,("owner"                   , scope EU4Country   . compoundMessage MsgOwner)
        ,("random_active_trade_node", scope EU4TradeNode . compoundMessage MsgRandomActiveTradeNode)
        ,("random_ally"             , scope EU4Country   . compoundMessage MsgRandomAlly)
        ,("random_core_country"     , scope EU4Country   . compoundMessage MsgRandomCoreCountry)
        ,("random_country"          , scope EU4Country   . compoundMessage MsgRandomCountry)
        ,("random_known_country"    , scope EU4Country   . compoundMessage MsgRandomKnownCountry)
        ,("random_list"             ,                      compoundMessage MsgRandom)
        ,("random_neighbor_country" , scope EU4Country   . compoundMessage MsgRandomNeighborCountry)
        ,("random_neighbor_province", scope EU4Province  . compoundMessage MsgRandomNeighborProvince)
        ,("random_owned_province"   , scope EU4Province  . compoundMessage MsgRandomOwnedProvince)
        ,("random_province"         , scope EU4Province  . compoundMessage MsgRandomProvince)
        ,("random_rival_country"    , scope EU4Country   . compoundMessage MsgRandomRival)
        -- Random
        ,("random", random)
        -- Simple generic statements (RHS is a localizable atom)
        ,("add_great_project"     , withLocAtom MsgStartConstructingGreatProject)
        ,("change_government"     , withLocAtom MsgChangeGovernment)
        ,("continent"             , withLocAtom MsgContinentIs)
        ,("change_culture"        , withLocAtom MsgChangeCulture)
        ,("change_primary_culture", withLocAtom MsgChangePrimaryCulture)
        ,("change_province_name"  , withLocAtom MsgChangeProvinceName) -- will usually fail localization
        ,("colonial_region"       , withLocAtom MsgColonialRegion)
        ,("culture"               , withLocAtom MsgCultureIs)
        ,("culture_group"         , withLocAtom MsgCultureIsGroup)
        ,("dynasty"               , withLocAtom MsgRulerIsDynasty)
        ,("end_disaster"          , withLocAtom MsgDisasterEnds)
        ,("government"            , withLocAtom MsgGovernmentIs)
        ,("has_advisor"           , withLocAtom MsgHasAdvisor)
        ,("has_active_policy"     , withLocAtom MsgHasActivePolicy)
        ,("has_construction"      , withLocAtom MsgConstructing)
        ,("has_disaster"          , withLocAtom MsgDisasterOngoing)
        ,("has_great_project"     , withLocAtom MsgConstructingGreatProject)
        ,("has_idea"              , withLocAtom MsgHasIdea)
        ,("has_terrain"           , withLocAtom MsgHasTerrain)
        ,("kill_advisor"          , withLocAtom MsgAdvisorDies)
        ,("primary_culture"       , withLocAtom MsgPrimaryCultureIs)
        ,("region"                , withLocAtom MsgRegionIs)
        ,("remove_advisor"        , withLocAtom MsgLoseAdvisor)
        ,("rename_capital"        , withLocAtom MsgRenameCapital) -- will usually fail localization
        -- RHS is a province ID
        ,("capital"           , withProvince MsgCapitalIs)
        ,("controls"          , withProvince MsgControls)
        ,("owns"              , withProvince MsgOwns)
        ,("owns_core_province", withProvince MsgOwnsCore)
        ,("owns_or_vassal_of" , withProvince MsgOwnsOrVassal)
        ,("province_id"       , withProvince MsgProvinceIs)
        ,("set_capital"       , withProvince MsgSetCapital)
        -- RHS is a flag OR a province ID
        ,("add_permanent_claim", withFlagOrProvince MsgGainPermanentClaimCountry MsgGainPermanentClaimProvince)
        ,("cavalry"            , withFlagOrProvince MsgCavalrySpawnsCountry MsgCavalrySpawnsProvince)
        ,("infantry"           , withFlagOrProvince MsgInfantrySpawnsCountry MsgInfantrySpawnsProvince)
        ,("remove_core"        , withFlagOrProvince MsgLoseCoreCountry MsgLoseCoreProvince)
        -- RHS is a flag or province id, but the statement's meaning depends on the scope
        ,("has_discovered"     , withFlagOrProvinceEU4Scope MsgHasDiscovered MsgDiscoveredBy) -- scope sensitive
        -- RHS is an advisor ID (TODO: parse advisor files)
        ,("advisor_exists"     , numeric MsgAdvisorExists)
        ,("is_advisor_employed", numeric MsgAdvisorIsEmployed)
        -- Simple generic statements (typewriter face)
        ,("clr_country_flag" , withNonlocAtom2 MsgCountryFlag MsgClearFlag)
        ,("clr_province_flag", withNonlocAtom2 MsgProvinceFlag MsgClearFlag)
        ,("clr_ruler_flag"   , withNonlocAtom2 MsgRulerFlag MsgClearFlag)
        ,("has_country_flag" , withNonlocAtom2 MsgCountryFlag MsgHasFlag)
        ,("has_global_flag"  , withNonlocAtom2 MsgGlobalFlag MsgHasFlag)
        ,("has_province_flag", withNonlocAtom2 MsgProvinceFlag MsgHasFlag)
        ,("has_ruler_flag"   , withNonlocAtom2 MsgRulerFlag MsgHasFlag)
        ,("set_country_flag" , withNonlocAtom2 MsgCountryFlag MsgSetFlag)
        ,("set_global_flag"  , withNonlocAtom2 MsgGlobalFlag MsgSetFlag)
        ,("set_province_flag", withNonlocAtom2 MsgProvinceFlag MsgSetFlag)
        ,("set_ruler_flag"   , withNonlocAtom2 MsgRulerFlag MsgSetFlag)
        -- Simple generic statements with icon
        ,("advisor"                 , withLocAtomIcon MsgHasAdvisorType)
        ,("change_technology_group" , withLocAtomIcon MsgChangeTechGroup)
        ,("change_trade_goods"      , withLocAtomIcon MsgChangeGoods)
        ,("change_unit_type"        , withLocAtomIcon MsgChangeUnitType)
        ,("create_advisor"          , withLocAtomIcon MsgCreateAdvisor)
        ,("dominant_religion"       , withLocAtomIcon MsgDominantReligion)
        ,("has_building"            , withLocAtomIcon MsgHasBuilding)
        ,("has_idea_group"          , withLocAtomIcon MsgHasIdeaGroup) -- FIXME: icon fails
        ,("full_idea_group"         , withLocAtomIcon MsgFullIdeaGroup)
        ,("hre_religion"            , withLocAtomIcon MsgHREReligion)
        ,("is_religion_enabled"     , withLocAtomIcon MsgReligionEnabled)
        ,("remove_estate"           , withLocAtomIcon MsgRemoveFromEstate )
        ,("secondary_religion"      , withLocAtomIcon MsgSecondaryReligion)
        ,("set_hre_heretic_religion", withLocAtomIcon MsgSetHREHereticReligion)
        ,("set_hre_religion"        , withLocAtomIcon MsgSetHREReligion)
        ,("technology_group"        , withLocAtomIcon MsgTechGroup)
        ,("trade_goods"             , withLocAtomIcon MsgProducesGoods)
        ,("has_estate"              , withLocAtomIconEU4Scope MsgEstateExists MsgHasEstate)
        ,("set_estate"              , withLocAtomIcon MsgAssignToEstate)
        ,("is_monarch_leader"       , withLocAtomAndIcon "ruler general" MsgRulerIsGeneral)
        -- Simple generic statements with flag
        ,("alliance_with"           , withFlag MsgAlliedWith)
        ,("cede_province"           , withFlag MsgCedeProvinceTo)
        ,("change_tag"              , withFlag MsgChangeTag)
        ,("controlled_by"           , withFlag MsgControlledBy)
        ,("defensive_war_with"      , withFlag MsgDefensiveWarAgainst)
        ,("discover_country"        , withFlag MsgDiscoverCountry)
        ,("add_claim"               , withFlag MsgGainClaim)
        ,("create_alliance"         , withFlag MsgCreateAlliance)
        ,("free_vassal"             , withFlag MsgFreeVassal)
        ,("galley"                  , withFlag MsgGalley)
        ,("heavy_ship"              , withFlag MsgHeavyShip)
        ,("inherit"                 , withFlag MsgInherit)
        ,("is_neighbor_of"          , withFlag MsgNeighbors)
        ,("is_league_enemy"         , withFlag MsgIsLeagueEnemy)
        ,("is_subject_of"           , withFlag MsgIsSubjectOf)
        ,("junior_union_with"       , withFlag MsgJuniorUnionWith)
        ,("light_ship"              , withFlag MsgLightShip)
        ,("marriage_with"           , withFlag MsgRoyalMarriageWith)
        ,("offensive_war_with"      , withFlag MsgOffensiveWarAgainst)
        ,("overlord_of"             , withFlag MsgOverlordOf)
        ,("owned_by"                , withFlag MsgOwnedBy)
        ,("release"                 , withFlag MsgReleaseVassal)
        ,("senior_union_with"       , withFlag MsgSeniorUnionWith)
        ,("sieged_by"               , withFlag MsgUnderSiegeBy)
        ,("is_strongest_trade_power", withFlag MsgStrongestTradePower)
        ,("tag"                     , withFlag MsgCountryIs)
        ,("truce_with"              , withFlag MsgTruceWith)
        ,("vassal_of"               , withFlag MsgVassalOf)
        ,("war_with"                , withFlag MsgAtWarWith)
        ,("white_peace"             , withFlag MsgMakeWhitePeace)
        -- Simple generic statements with flag or "yes"/"no"
        ,("exists", withFlagOrBool MsgExists MsgCountryExists)
        -- Statements that may be an icon, a flag, or a pronoun (such as ROOT)
        -- Boolean argument is whether to emit an icon.
        ,("religion"       , iconOrFlag MsgReligion MsgSameReligion)
        ,("religion_group" , iconOrFlag MsgReligionGroup MsgSameReligionGroup)
        ,("change_religion", iconOrFlag MsgChangeReligion MsgChangeSameReligion)
        -- Statements that may be either a tag or a province
        ,("is_core" , tagOrProvince MsgIsCoreOf MsgHasCoreOn)
        ,("is_claim", tagOrProvince MsgHasClaim MsgHasClaimOn)
        -- Boolean statements
        ,("ai"                          , withBool MsgIsAIControlled)
        ,("allows_female_emperor"       , withBool MsgFemaleEmperorAllowed)
        ,("always"                      , withBool MsgAlways)
        ,("has_any_disaster"            , withBool MsgHasAnyDisaster)
        ,("has_cardinal"                , withBool MsgHasCardinal)
        ,("has_factions"                , withBool MsgHasFactions)
        ,("has_female_heir"             , withBool MsgHasFemaleHeir)
        ,("has_heir"                    , withBool MsgHasHeir)
        ,("has_missionary"              , withBool MsgHasMissionary)
        ,("has_owner_culture"           , withBool MsgHasOwnerCulture)
        ,("has_owner_religion"          , withBool MsgHasOwnerReligion)
        ,("has_parliament"              , withBool MsgHasParliament)
        ,("has_port"                    , withBool MsgHasPort)
        ,("has_seat_in_parliament"      , withBool MsgHasSeatInParliament)
        ,("has_regency"                 , withBool MsgIsInRegency)
        ,("has_siege"                   , withBool MsgUnderSiege)
        ,("has_secondary_religion"      , withBool MsgHasSecondaryReligion)
        ,("has_truce"                   , withBool MsgHasTruce)
        ,("has_wartaxes"                , withBool MsgHasWarTaxes)
        ,("hre_leagues_enabled"         , withBool MsgHRELeaguesEnabled)
        ,("hre_religion_locked"         , withBool MsgHREReligionLocked)
        ,("hre_religion_treaty"         , withBool MsgHREWestphalia)
        ,("is_at_war"                   , withBool MsgAtWar)
        ,("is_bankrupt"                 , withBool MsgIsBankrupt)
        ,("is_capital"                  , withBool MsgIsCapital)
        ,("is_city"                     , withBool MsgIsCity)
        ,("is_colony"                   , withBool MsgIsColony)
        ,("is_colonial_nation"          , withBool MsgIsColonialNation)
        ,("is_defender_of_faith"        , withBool MsgIsDefenderOfFaith)
        ,("is_force_converted"          , withBool MsgWasForceConverted)
        ,("is_former_colonial_nation"   , withBool MsgIsFormerColonialNation)
        ,("is_elector"                  , withBool MsgIsElector)
        ,("is_emperor"                  , withBool MsgIsEmperor)
        ,("is_female"                   , withBool MsgIsFemale)
        ,("is_in_league_war"            , withBool MsgIsInLeagueWar)
        ,("is_lesser_in_union"          , withBool MsgIsLesserInUnion)
        ,("is_looted"                   , withBool MsgIsLooted)
        ,("is_nomad"                    , withBool MsgIsNomad)
        ,("is_overseas"                 , withBool MsgIsOverseas)
        ,("is_part_of_hre"              , withBool MsgIsPartOfHRE)
        ,("is_playing_custom_nation"    , withBool MsgIsCustomNation)
        ,("is_random_new_world"         , withBool MsgRandomNewWorld)
        ,("is_reformation_center"       , withBool MsgIsCenterOfReformation)
        ,("is_religion_reformed"        , withBool MsgReligionReformed)
        ,("is_sea"                      , withBool MsgIsSea) -- province or trade node
        ,("is_subject"                  , withBool MsgIsSubject)
        ,("is_tribal"                   , withBool MsgIsTribal)
        ,("is_tutorial_active"          , withBool MsgIsInTutorial)
        ,("luck"                        , withBool MsgLucky)
        ,("normal_or_historical_nations", withBool MsgNormalOrHistoricalNations)
        ,("papacy_active"               , withBool MsgPapacyIsActive)
        ,("primitives"                  , withBool MsgPrimitives)
        ,("set_hre_religion_locked"     , withBool MsgSetHREReligionLocked)
        ,("set_in_empire"               , withBool MsgSetInEmpire)
        ,("unit_in_siege"               , withBool MsgUnderSiege) -- duplicate?
        ,("was_player"                  , withBool MsgHasBeenPlayer)
        -- Statements that may be numeric or a tag
        ,("num_of_cities", numericOrTag MsgNumCities MsgNumCitiesThan)
        -- Signed numeric statements
        ,("tolerance_to_this", numeric MsgToleranceToThis)
        -- Special cases
        ,("legitimacy_or_horde_unity", numeric MsgLegitimacyOrHordeUnity)
        -- Number of provinces of some kind, mostly religions and trade goods
        ,("orthodox"      , numProvinces "orthodox" MsgReligionProvinces)
        ,("cloth"         , numProvinces "cloth" MsgGoodsProvinces)
        ,("chinaware"     , numProvinces "chinaware" MsgGoodsProvinces)
        ,("copper"        , numProvinces "copper" MsgGoodsProvinces)
        ,("fish"          , numProvinces "fish" MsgGoodsProvinces)
        ,("fur"           , numProvinces "fur" MsgGoodsProvinces)
        ,("gold"          , numProvinces "gold" MsgGoodsProvinces)
        ,("grain"         , numProvinces "grain" MsgGoodsProvinces)
        ,("iron"          , numProvinces "iron" MsgGoodsProvinces)
        ,("ivory"         , numProvinces "ivory" MsgGoodsProvinces)
        ,("naval_supplies", numProvinces "fish" MsgGoodsProvinces)
        ,("salt"          , numProvinces "salt" MsgGoodsProvinces)
        ,("slaves"        , numProvinces "slaves" MsgGoodsProvinces)
        ,("spices"        , numProvinces "spices" MsgGoodsProvinces)
        ,("wine"          , numProvinces "wine" MsgGoodsProvinces)
        ,("wool"          , numProvinces "wool" MsgGoodsProvinces)
        -- Special
        ,("add_core"            , addCore)
        ,("add_manpower"        , gainManpower)
        ,("dominant_culture"    , dominantCulture)
        ,("faction_in_power"    , factionInPower)
        ,("government_rank"     , govtRank)
        ,("has_dlc"             , hasDlc)
        ,("hre_reform_level"    , hreReformLevel)
        ,("is_month"            , isMonth)
        ,("piety"               , piety)
        ,("range"               , range)
        ,("set_government_rank" , setGovtRank)
        -- Special complex statements
        ,("add_casus_belli"              , addCB True)
        ,("add_faction_influence"        , factionInfluence)
        ,("add_estate_loyalty"           , textValue "estate" "loyalty" MsgAddEstateLoyalty MsgAddEstateLoyalty tryLoc)
        ,("add_estate_influence_modifier", estateInfluenceModifier MsgEstateInfluenceModifier)
        ,("add_opinion"                  , opinion MsgAddOpinion MsgAddOpinionDur)
        ,("reverse_add_opinion"          , opinion MsgReverseAddOpinion MsgReverseAddOpinionDur)
        ,("area"                         , area)
        ,("custom_trigger_tooltip"       , customTriggerTooltip)
        ,("define_heir"                  , defineHeir)
        ,("build_to_forcelimit"          , buildToForcelimit)
        ,("check_variable"               , textValue "which" "value" MsgCheckVariable MsgCheckVariable tryLoc)
        ,("country_event"                , scope EU4Country . triggerEvent MsgCountryEvent)
        ,("declare_war_with_cb"          , declareWarWithCB)
        ,("define_advisor"               , defineAdvisor)
        ,("define_ruler"                 , defineRuler)
        ,("estate_influence"             , textValue "estate" "influence" MsgEstateInfluence MsgEstateInfluence tryLoc)
        ,("estate_loyalty"               , textValue "estate" "loyalty" MsgEstateLoyalty MsgEstateLoyalty tryLoc)
        ,("had_country_flag"             , textValue "flag" "days" MsgHadCountryFlag MsgHadCountryFlag tryLoc)
        ,("had_global_flag"              , textValue "flag" "days" MsgHadGlobalFlag MsgHadGlobalFlag tryLoc)
        ,("had_province_flag"            , textValue "flag" "days" MsgHadProvinceFlag MsgHadProvinceFlag tryLoc)
        ,("had_ruler_flag"               , textValue "flag" "days" MsgHadRulerFlag MsgHadRulerFlag tryLoc)
        ,("has_estate_influence_modifier", hasEstateInfluenceModifier)
        ,("has_opinion"                  , hasOpinion)
        ,("has_opinion_modifier"         , opinion MsgHasOpinionMod (\what who _years -> MsgHasOpinionMod what who))
        ,("province_event"               , scope EU4Province . triggerEvent MsgProvinceEvent)
        ,("remove_opinion"               , opinion MsgRemoveOpinionMod (\what who _years -> MsgRemoveOpinionMod what who))
        ,("religion_years"               , religionYears)
        ,("reverse_add_casus_belli"      , addCB False)
        ,("trigger_switch"               , triggerSwitch)
        ,("num_of_religion"              , textValue "religion" "value" MsgNumOfReligion MsgNumOfReligion tryLoc)
        -- Rebels
        ,("can_spawn_rebels"  , canSpawnRebels)
        ,("create_revolt"     , spawnRebels Nothing)
        ,("has_spawned_rebels", hasSpawnedRebels)
        ,("likely_rebels"     , canSpawnRebels)
        ,("spawn_rebels"      , spawnRebels Nothing)
        -- Specific rebels
        ,("anti_tax_rebels"   , spawnRebels (Just "anti_tax_rebels"))
        ,("nationalist_rebels", spawnRebels (Just "nationalist_rebels"))
        ,("noble_rebels"      , spawnRebels (Just "noble_rebels"))
        -- Idea groups
        ,("aristocracy_ideas"   , hasIdea MsgHasAristocraticIdea)
        ,("defensive_ideas"     , hasIdea MsgHasDefensiveIdea)
        ,("economic_ideas"      , hasIdea MsgHasEconomicIdea)
        ,("innovativeness_ideas", hasIdea MsgHasInnovativeIdea)
        ,("maritime_ideas"      , hasIdea MsgHasMaritimeIdea)
        ,("offensive_ideas"     , hasIdea MsgHasOffensiveIdea)
        -- Ignored
        ,("custom_tooltip", const (plainMsg "（自定义工具提示 - 请删除本行）"))
        ,("tooltip"       , const (plainMsg "（解释性工具提示 - 请删除本行）"))
        ]

ppOne :: (EU4Info g, Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
ppOne stmt@[pdx| %lhs = %rhs |] = case lhs of
    GenericLhs label -> case Tr.lookup (TE.encodeUtf8 (T.toLower label)) ppHandlers of
        Just handler -> handler stmt
        -- default
        Nothing -> if isTag label
             then case rhs of
                CompoundRhs scr ->
                    withCurrentIndent $ \_ -> do -- force indent level at least 1
                        [lflag] <- plainMsg =<< (<> ":") <$> flagText label
                        scriptMsgs <- ppMany scr
                        return (lflag : scriptMsgs)
                _ -> preStatement stmt
             else do
                mloc <- getGameL10nIfPresent label
                case mloc of
                    -- Check for localizable atoms, e.g. regions
                    Just loc -> compound loc stmt
                    Nothing -> preStatement stmt
    AtLhs _ -> return [] -- don't know how to handle these
    IntLhs n -> do -- Treat as a province tag
        let provN = T.pack (show n)
        prov_loc <- getGameL10nDefault ("Province " <> provN) ("PROV" <> provN)
        case rhs of
            CompoundRhs scr -> do
                header <- msgToPP (MsgProvince prov_loc)
                scriptMsgs <- ppMany scr
                return (header ++ scriptMsgs)
            _ -> preStatement stmt
    CustomLhs _ -> preStatement stmt
ppOne stmt = preStatement stmt


-----------------------------------------------------------------
-- Script handlers that should be used directly, not via ppOne --
-----------------------------------------------------------------

data MTTH = MTTH
        {   mtth_years :: Maybe Int
        ,   mtth_months :: Maybe Int
        ,   mtth_days :: Maybe Int
        ,   mtth_modifiers :: [MTTHModifier] -- TODO
        } deriving Show
data MTTHModifier = MTTHModifier
        {   mtthmod_factor :: Maybe Double
        ,   mtthmod_conditions :: GenericScript
        } deriving Show
newMTTH :: MTTH
newMTTH = MTTH Nothing Nothing Nothing []
newMTTHMod :: MTTHModifier
newMTTHMod = MTTHModifier Nothing []
pp_mtth :: (EU4Info g, Monad m) => GenericScript -> PPT g m Doc
pp_mtth = pp_mtth' . foldl' addField newMTTH
    where
        addField mtth [pdx| years    = !n   |] = mtth { mtth_years = Just n }
        addField mtth [pdx| months   = !n   |] = mtth { mtth_months = Just n }
        addField mtth [pdx| days     = !n   |] = mtth { mtth_days = Just n }
        addField mtth [pdx| modifier = @rhs |] = addMTTHMod mtth rhs
        addField mtth _ = mtth -- unrecognized
        addMTTHMod mtth scr = mtth {
                mtth_modifiers = mtth_modifiers mtth
                                 ++ [foldl' addMTTHModField newMTTHMod scr] } where
            addMTTHModField mtthmod [pdx| factor = !n |]
                = mtthmod { mtthmod_factor = Just n }
            addMTTHModField mtthmod stmt -- anything else is a condition
                = mtthmod { mtthmod_conditions = mtthmod_conditions mtthmod ++ [stmt] }
        pp_mtth' (MTTH myears mmonths mdays modifiers) = do
            modifiers_pp'd <- intersperse PP.line <$> mapM pp_mtthmod modifiers
            let hasYears = isJust myears
                hasMonths = isJust mmonths
                hasDays = isJust mdays
                hasModifiers = not (null modifiers)
            return . mconcat $
                case myears of
                    Just years ->
                        [PP.int years, PP.space, Doc.strictText $ plural years "year" "years"]
                        ++
                        if hasMonths && hasDays then [",", PP.space]
                        else if hasMonths || hasDays then ["and", PP.space]
                        else []
                    Nothing -> []
                ++
                case mmonths of
                    Just months ->
                        [PP.int months, PP.space, Doc.strictText $ plural months "month" "months"]
                    _ -> []
                ++
                case mdays of
                    Just days ->
                        (if hasYears && hasMonths then ["and", PP.space]
                         else []) -- if years but no months, already added "and"
                        ++
                        [PP.int days, PP.space, Doc.strictText $ plural days "day" "days"]
                    _ -> []
                ++
                (if hasModifiers then
                    [PP.line, "<br/>'''修正'''", PP.line]
                    ++ modifiers_pp'd
                 else [])
        pp_mtthmod (MTTHModifier (Just factor) conditions) =
            case conditions of
                [_] -> do
                    conditions_pp'd <- pp_script conditions
                    return . mconcat $
                        [conditions_pp'd
                        ,PP.enclose ": '''×" "'''" (Doc.pp_float factor)
                        ]
                _ -> do
                    conditions_pp'd <- indentUp (pp_script conditions)
                    return . mconcat $
                        ["*"
                        ,PP.enclose "'''×" "''':" (Doc.pp_float factor)
                        ,PP.line
                        ,conditions_pp'd
                        ]
        pp_mtthmod (MTTHModifier Nothing _)
            = return "(invalid modifier! Bug in extractor?)"

--------------------------------
-- General statement handlers --
--------------------------------

compound :: (EU4Info g, Monad m) =>
    Text -> GenericStatement -> PPT g m IndentedMessages
compound header [pdx| %_ = @scr |]
    = withCurrentIndent $ \_ -> do -- force indent level at least 1
        headerMsg <- plainMsg (header <> ":")
        scriptMsgs <- ppMany scr
        return $ headerMsg ++ scriptMsgs
compound _ stmt = preStatement stmt

compoundMessage :: (EU4Info g, Monad m) =>
    ScriptMessage -> GenericStatement -> PPT g m IndentedMessages
compoundMessage header [pdx| %_ = @scr |]
    = withCurrentIndent $ \i -> do
        script_pp'd <- ppMany scr
        return ((i, header) : script_pp'd)
compoundMessage _ stmt = preStatement stmt

-- RHS is a localizable atom.
withLocAtom :: (IsGameData (GameData g),
                IsGameState (GameState g),
                Monad m) =>
    (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withLocAtom msg [pdx| %_ = ?key |]
    = msgToPP =<< msg <$> getGameL10n key
withLocAtom _ stmt = preStatement stmt

-- RHS is a localizable atom and we need a second one (passed to message as
-- first arg).
withLocAtom2 :: (IsGameData (GameData g),
                 IsGameState (GameState g),
                 Monad m) =>
    ScriptMessage
        -> (Text -> Text -> Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withLocAtom2 inMsg msg [pdx| %_ = ?key |]
    = msgToPP =<< msg <$> pure key <*> messageText inMsg <*> getGameL10n key
withLocAtom2 _ _ stmt = preStatement stmt

withLocAtomAndIcon :: (IsGameData (GameData g),
                       IsGameState (GameState g),
                       Monad m) =>
    Text
        -> (Text -> Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withLocAtomAndIcon iconkey msg [pdx| %_ = $key |]
    = do what <- getGameL10n key
         msgToPP $ msg (iconText iconkey) what
withLocAtomAndIcon _ _ stmt = preStatement stmt

withLocAtomIcon :: (IsGameData (GameData g),
                    IsGameState (GameState g),
                    Monad m) =>
    (Text -> Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withLocAtomIcon msg stmt@[pdx| %_ = $key |]
    = withLocAtomAndIcon key msg stmt
withLocAtomIcon _ stmt = preStatement stmt

withLocAtomIconEU4Scope :: (EU4Info g, Monad m) =>
    (Text -> Text -> ScriptMessage)
        -> (Text -> Text -> ScriptMessage)
        -> GenericStatement -> PPT g m IndentedMessages
withLocAtomIconEU4Scope countrymsg provincemsg stmt = do
    thescope <- getCurrentScope
    case thescope of
        Just EU4Country -> withLocAtomIcon countrymsg stmt
        Just EU4Province -> withLocAtomIcon provincemsg stmt
        _ -> preStatement stmt -- others don't make sense

withProvince :: (IsGameData (GameData g),
                 IsGameState (GameState g),
                 Monad m) =>
    (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withProvince msg [pdx| %lhs = !provid |]
    = withLocAtom msg [pdx| %lhs = $(T.pack ("PROV" <> show (provid::Int))) |]
withProvince _ stmt = preStatement stmt

-- As withLocAtom but no l10n.
-- Currently unused
--withNonlocAtom :: (Text -> ScriptMessage) -> GenericStatement -> PP extra IndentedMessages
--withNonlocAtom msg [pdx| %_ = ?text |] = msgToPP $ msg text
--withNonlocAtom _ stmt = preStatement stmt

-- As withNonlocAtom but with an additional bit of text.
withNonlocAtom2 :: (IsGameData (GameData g),
                    IsGameState (GameState g),
                    Monad m) =>
    ScriptMessage
        -> (Text -> Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withNonlocAtom2 submsg msg [pdx| %_ = ?txt |] = do
    extratext <- messageText submsg
    msgToPP $ msg extratext txt
withNonlocAtom2 _ _ stmt = preStatement stmt

-- Table of script atom -> icon key. Only ones that are different are listed.
scriptIconTable :: HashMap Text Text
scriptIconTable = HM.fromList
    [("master_of_mint", "master of mint")
    ,("natural_scientist", "natural scientist")
    ,("colonial_governor", "colonial governor")
    ,("diplomat", "diplomat_adv")
    ,("naval_reformer", "naval reformer")
    ,("navy_reformer", "naval reformer") -- these are both used!
    ,("army_organizer", "army organizer")
    ,("army_reformer", "army reformer")
    ,("grand_captain", "grand captain")
    ,("master_recruiter", "master recruiter")
    ,("military_engineer", "military engineer")
    ,("spy_ideas", "espionage")
    ,("economic_ideas", "economic")
    ,("trade_ideas", "trade")
    ,("administrative_ideas", "administrative")
    ,("innovativeness_ideas", "innovative")
    ,("aristocracy_ideas", "aristocratic")
    ,("religious_ideas", "religious")
    ,("diplomatic_ideas", "diplomatic")
    ,("influence_ideas", "influence")
    ,("estate_church", "clergy")
    ,("estate_nobles", "nobles")
    ,("estate_burghers", "burghers")
    ,("estate_cossacks", "cossacks")
    ,("estate_nomadic_tribes", "tribes")
    ,("estate_dhimmi", "dhimmi")
    ,("base production", "production")
    ,("particularist", "particularists")
    ,("is_monarch_leader", "ruler general")
    ,("piety", "being pious") -- chosen arbitrarily
    ,("nomad_group", "nomadic")
    ,("tengri_pagan_reformed", "tengri")
    ,("norse_pagan_reformed", "norse")
    ,("mesoamerican_religion", "mayan")
    ]

-- Given a script atom, return the corresponding icon key, if any.
iconKey :: Text -> Maybe Text
iconKey atom = HM.lookup atom scriptIconTable

iconFileTable :: HashMap Text Text
iconFileTable = HM.fromList
    [("global tax modifier", "national tax modifier")
    ,("stability cost", "stability cost modifier")
    ,("land maintenance", "land maintenance modifier")
    ,("tolerance of the true faith", "tolerance own")
    ,("light ship combat ability", "light ship power")
    ]

-- Given an {{icon}} key, give the corresponding icon file name.
--
-- Needed for idea groups, which don't use {{icon}}.
iconFile :: Text -> Text
iconFile s = HM.lookupDefault s s iconFileTable
-- ByteString version
iconFileB :: ByteString -> ByteString
iconFileB = TE.encodeUtf8 . iconFile . TE.decodeUtf8

-- As generic_icon except
-- * say "same as <foo>" if foo refers to a country (in which case, add a flag)
-- * may not actually have an icon (localization file will know if it doesn't)
iconOrFlag :: (IsGameData (GameData g),
               IsGameState (GameState g),
               Monad m) =>
    (Text -> Text -> ScriptMessage)
        -> (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
iconOrFlag iconmsg flagmsg [pdx| %_ = $name |] = msgToPP =<< do
    nflag <- flag name -- laziness means this might not get evaluated
    if isTag name || isPronoun name
        then return . flagmsg . Doc.doc2text $ nflag
        else iconmsg <$> return (iconText . HM.lookupDefault name name $ scriptIconTable)
                     <*> getGameL10n name
iconOrFlag _ _ stmt = plainMsg $ pre_statement' stmt

tagOrProvince :: (IsGameData (GameData g),
                  IsGameState (GameState g),
                  Monad m) =>
    (Text -> ScriptMessage)
        -> (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
tagOrProvince tagmsg provmsg stmt@[pdx| %_ = ?!eobject |]
    = msgToPP =<< case eobject of
            Just (Right tag) -> do -- is a tag
                tagflag <- flag tag
                return . tagmsg . Doc.doc2text $ tagflag
            Just (Left provid) -> do -- is a province id
                prov_loc <- getProvLoc provid
                return . provmsg $ prov_loc
            Nothing -> return (preMessage stmt)
tagOrProvince _ _ stmt = preStatement stmt

-- Numeric statement.
-- TODO (if necessary): allow operators other than = and pass them to message
-- handler
numeric :: (IsGameState (GameState g), Monad m) =>
    (Double -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
numeric msg [pdx| %_ = !n |] = msgToPP $ msg n
numeric _ stmt = plainMsg $ pre_statement' stmt

numericOrTag :: (IsGameData (GameData g),
                 IsGameState (GameState g),
                 Monad m) =>
    (Double -> ScriptMessage)
        -> (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
numericOrTag numMsg tagMsg stmt@[pdx| %_ = %rhs |] = msgToPP =<<
    case floatRhs rhs of
        Just n -> return $ numMsg n
        Nothing -> case textRhs rhs of
            Just t -> do -- assume it's a country
                tflag <- flag t
                return $ tagMsg (Doc.doc2text tflag)
            Nothing -> return (preMessage stmt)
numericOrTag _ _ stmt = preStatement stmt

-- Generic statement referring to a country. Use a flag.
withFlag :: (IsGameData (GameData g), IsGameState (GameState g), Monad m) =>
    (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withFlag msg [pdx| %_ = $who |] = msgToPP =<< do
    whoflag <- flag who
    return . msg . Doc.doc2text $ whoflag
withFlag _ stmt = plainMsg $ pre_statement' stmt

withBool :: (IsGameState (GameState g), Monad m) =>
    (Bool -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withBool msg stmt = do
    fullmsg <- withBool' msg stmt
    maybe (preStatement stmt)
          return
          fullmsg

withBool' :: (IsGameState (GameState g), Monad m) =>
    (Bool -> ScriptMessage)
        -> GenericStatement
        -> PPT g m (Maybe IndentedMessages)
withBool' msg [pdx| %_ = ?yn |] | T.map toLower yn `elem` ["yes","no","false"]
    = fmap Just . msgToPP $ case T.toCaseFold yn of
        "yes" -> msg True
        "no"  -> msg False
        "false" -> msg False
        _     -> error "impossible: withBool matched a string that wasn't yes, no or false"
withBool' _ _ = return Nothing

-- Statement may have "yes"/"no" or a tag.
withFlagOrBool :: (IsGameData (GameData g),
                   IsGameState (GameState g),
                   Monad m) =>
    (Bool -> ScriptMessage)
        -> (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withFlagOrBool bmsg _ [pdx| %_ = yes |] = msgToPP (bmsg True)
withFlagOrBool bmsg _ [pdx| %_ = no  |]  = msgToPP (bmsg False)
withFlagOrBool _ tmsg stmt = withFlag tmsg stmt

numericIcon :: (IsGameState (GameState g), Monad m) =>
    Text
        -> (Text -> Double -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
numericIcon the_icon msg [pdx| %_ = !amt |]
    = msgToPP $ msg (iconText the_icon) amt
numericIcon _ _ stmt = plainMsg $ pre_statement' stmt

numericIconBonus :: (EU4Info g, Monad m) =>
    Text
        -> (Text -> Double -> ScriptMessage)
        -> (Text -> Double -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
numericIconBonus the_icon plainmsg yearlymsg [pdx| %_ = !amt |]
    = do
        mscope <- getCurrentScope
        let icont = iconText the_icon
            yearly = msgToPP $ yearlymsg icont amt
        case mscope of
            Nothing -> yearly -- ideas / bonuses
            Just thescope -> case thescope of
                EU4Bonus -> yearly
                _ -> -- act as though it's country for all others
                    msgToPP $ plainmsg icont amt
numericIconBonus _ _ _ stmt = plainMsg $ pre_statement' stmt

----------------------
-- Text/value pairs --
----------------------

-- This is for statements of the form
--      head = {
--          what = some_atom
--          value = 3
--      }
-- e.g.
--      num_of_religion = {
--          religion = catholic
--          value = 0.5
--      }
-- There are several statements of this form, but with different "what" labels,
-- so the first parameter says what that label is. There's also one for value,
-- in case there are other labels for that.
--
-- There are two message parameters, one for value < 1 and one for value >= 1.
-- In the example num_of_religion, value is interpreted as a percentage of
-- provinces if less than 1, or a number of provinces otherwise. These require
-- rather different messages.
--
-- We additionally attempt to localize the RHS of "what". If it has no
-- localization string, it gets wrapped in a tt element instead.

-- convenience synonym
tryLoc :: (IsGameData (GameData g), Monad m) => Text -> PPT g m (Maybe Text)
tryLoc = getGameL10nIfPresent

data TextValue = TextValue
        {   tv_what :: Maybe Text
        ,   tv_value :: Maybe Double
        }
newTV :: TextValue
newTV = TextValue Nothing Nothing
textValue :: forall g m. (IsGameState (GameState g), Monad m) =>
    Text                                             -- ^ Label for "what"
        -> Text                                      -- ^ Label for "how much"
        -> (Text -> Text -> Double -> ScriptMessage) -- ^ Message constructor, if abs value < 1
        -> (Text -> Text -> Double -> ScriptMessage) -- ^ Message constructor, if abs value >= 1
        -> (Text -> PPT g m (Maybe Text)) -- ^ Action to localize, get icon, etc. (applied to RHS of "what")
        -> GenericStatement -> PPT g m IndentedMessages
textValue whatlabel vallabel smallmsg bigmsg loc stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_tv (foldl' addLine newTV scr)
    where
        addLine :: TextValue -> GenericStatement -> TextValue
        addLine tv [pdx| $label = ?what |] | label == whatlabel
            = tv { tv_what = Just what }
        addLine tv [pdx| $label = !val |] | label == vallabel
            = tv { tv_value = Just val }
        addLine nor _ = nor
        pp_tv :: TextValue -> PPT g m ScriptMessage
        pp_tv tv = case (tv_what tv, tv_value tv) of
            (Just what, Just value) -> do
                mwhat_loc <- loc what
                let what_icon = iconText what
                    what_loc = fromMaybe ("<tt>" <> what <> "</tt>") mwhat_loc
                return $ (if abs value < 1 then smallmsg else bigmsg) what_icon what_loc value
            _ -> return $ preMessage stmt
textValue _ _ _ _ _ stmt = preStatement stmt

-- | Statements of the form
--      has_trade_modifier = {
--          who = ROOT
--          name = merchant_recalled
--      }
data TextAtom = TextAtom
        {   ta_what :: Maybe Text
        ,   ta_atom :: Maybe Text
        }
newTA :: TextAtom
newTA = TextAtom Nothing Nothing
textAtom :: forall g m. (IsGameData (GameData g),
                         IsGameState (GameState g),
                         Monad m) =>
    Text -- ^ Label for "what"
        -> Text -- ^ Label for atom
        -> (Text -> Text -> Text -> ScriptMessage) -- ^ Message constructor
        -> (Text -> PPT g m (Maybe Text)) -- ^ Action to localize, get icon, etc. (applied to RHS of "what")
        -> GenericStatement -> PPT g m IndentedMessages
textAtom whatlabel atomlabel msg loc stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_ta (foldl' addLine newTA scr)
    where
        addLine :: TextAtom -> GenericStatement -> TextAtom
        addLine ta [pdx| $label = ?what |]
            | label == whatlabel
            = ta { ta_what = Just what }
        addLine ta [pdx| $label = ?at |]
            | label == atomlabel
            = ta { ta_atom = Just at }
        addLine nor _ = nor
        pp_ta :: TextAtom -> PPT g m ScriptMessage
        pp_ta ta = case (ta_what ta, ta_atom ta) of
            (Just what, Just atom) -> do
                mwhat_loc <- loc what
                atom_loc <- getGameL10n atom
                let what_icon = iconText what
                    what_loc = fromMaybe ("<tt>" <> what <> "</tt>") mwhat_loc
                return $ msg what_icon what_loc atom_loc
            _ -> return $ preMessage stmt
textAtom _ _ _ _ stmt = preStatement stmt

-- AI decision factors

ppAiWillDo :: (EU4Info g, Monad m) => AIWillDo -> PPT g m IndentedMessages
ppAiWillDo (AIWillDo mbase mods) = do
    mods_pp'd <- fold <$> traverse ppAiMod mods
    let baseWtMsg = case mbase of
            Nothing -> MsgNoBaseWeight
            Just base -> MsgAIBaseWeight base
    iBaseWtMsg <- msgToPP baseWtMsg
    return $ iBaseWtMsg ++ mods_pp'd

ppAiMod :: (EU4Info g, Monad m) => AIModifier -> PPT g m IndentedMessages
ppAiMod (AIModifier (Just multiplier) triggers) = do
    triggers_pp'd <- ppMany triggers
    case triggers_pp'd of
        [(i, triggerMsg)] -> do
            triggerText <- messageText triggerMsg
            return [(i, MsgAIFactorOneline triggerText multiplier)]
        _ -> withCurrentIndentZero $ \i -> return $
            (i, MsgAIFactorHeader multiplier)
            : map (first succ) triggers_pp'd -- indent up
ppAiMod (AIModifier Nothing _) =
    plainMsg "(missing multiplier for this factor)"

---------------------------------
-- Specific statement handlers --
---------------------------------

-- Factions.
-- We want to use the faction influence icons, not the faction icons, so
-- textValue unfortunately doesn't work here.

facInfluence_iconkey :: Text -> Maybe Text
facInfluence_iconkey fac = case fac of
        -- Celestial empire
        "enuchs" {- sic -} -> Just "eunuchs influence"
        "temples"          -> Just "temples influence"
        "bureaucrats"      -> Just "bureaucrats influence"
        -- Merchant republic
        "mr_aristocrats"   -> Just "aristocrats influence"
        "mr_guilds"        -> Just "guilds influence"
        "mr_traders"       -> Just "traders influence"
        _ {- unknown -}    -> Nothing

fac_iconkey :: Text -> Maybe Text
fac_iconkey fac = case fac of
        -- Celestial empire
        "enuchs" {- sic -} -> Just "eunuchs"
        "temples"          -> Just "temples"
        "bureaucrats"      -> Just "bureaucrats"
        -- Merchant republic
        "mr_aristocrats"   -> Just "aristocrats"
        "mr_guilds"        -> Just "guilds"
        "mr_traders"       -> Just "traders"
        _ {- unknown -}    -> Nothing

data FactionInfluence = FactionInfluence {
        faction :: Maybe Text
    ,   influence :: Maybe Double
    }
newInfluence :: FactionInfluence
newInfluence = FactionInfluence Nothing Nothing
factionInfluence :: (IsGameData (GameData g),
                     IsGameState (GameState g),
                     Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
factionInfluence stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_influence (foldl' addField newInfluence scr)
    where
        pp_influence inf = case (faction inf, influence inf) of
            (Just fac, Just infl) ->
                let fac_icon = maybe ("<!-- " <> fac <> " -->") iconText (facInfluence_iconkey fac)
                in do
                    fac_loc <- getGameL10n fac
                    return $ MsgFactionGainInfluence fac_icon fac_loc infl
            _ -> return $ preMessage stmt
        addField :: FactionInfluence -> GenericStatement -> FactionInfluence
        addField inf [pdx| faction   = ?fac |] = inf { faction = Just fac }
        addField inf [pdx| influence = !amt |] = inf { influence = Just amt }
        addField inf _ = inf -- unknown statement
factionInfluence stmt = preStatement stmt

factionInPower :: (IsGameData (GameData g),
                   IsGameState (GameState g),
                   Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
factionInPower [pdx| %_ = ?fac |] | Just facKey <- fac_iconkey fac
    = do fac_loc <- getGameL10n fac
         msgToPP $ MsgFactionInPower (iconText facKey) fac_loc
factionInPower stmt = preStatement stmt

-- Modifiers

data Modifier = Modifier {
        mod_name :: Maybe Text
    ,   mod_key :: Maybe Text
    ,   mod_who :: Maybe Text
    ,   mod_duration :: Maybe Double
    ,   mod_power :: Maybe Double
    } deriving Show
newModifier :: Modifier
newModifier = Modifier Nothing Nothing Nothing Nothing Nothing

addModifierLine :: Modifier -> GenericStatement -> Modifier
addModifierLine apm [pdx| name     = ?name     |] = apm { mod_name = Just name }
addModifierLine apm [pdx| key      = ?key      |] = apm { mod_key = Just key }
addModifierLine apm [pdx| who      = ?tag      |] = apm { mod_who = Just tag }
addModifierLine apm [pdx| duration = !duration |] = apm { mod_duration = Just duration }
addModifierLine apm [pdx| power    = !power    |] = apm { mod_power = Just power }
addModifierLine apm _ = apm -- e.g. hidden = yes

maybeM :: Monad m => (a -> m b) -> Maybe a -> m (Maybe b)
maybeM f = maybe (return Nothing) (liftM Just . f)

addModifier :: (IsGameData (GameData g),
                IsGameState (GameState g),
                Monad m) =>
    ScriptMessage -> GenericStatement -> PPT g m IndentedMessages
addModifier kind stmt@(Statement _ OpEq (CompoundRhs scr)) = msgToPP =<<
    let modifier = foldl' addModifierLine newModifier scr
    in if isJust (mod_name modifier) || isJust (mod_key modifier) then do
        let mkey = mod_key modifier
            mname = mod_name modifier
        tkind <- messageText kind
        mwho <- maybe (return Nothing) (fmap (Just . Doc.doc2text) . flag) (mod_who modifier)
        mname_loc <- maybeM getGameL10n mname
        mkey_loc <- maybeM getGameL10n mkey
        let mdur = mod_duration modifier
            mname_or_key = maybe mkey Just mname
            mname_or_key_loc = maybe mkey_loc Just mname_loc

        return $ case mname_or_key of
            Just modid ->
                -- default presented name to mod id
                let name_loc = fromMaybe modid mname_or_key_loc
                in case (mwho, mod_power modifier, mdur) of
                    (Nothing,  Nothing,  Nothing)  -> MsgGainMod modid tkind name_loc
                    (Nothing,  Nothing,  Just dur) -> MsgGainModDur modid tkind name_loc dur
                    (Nothing,  Just pow, Nothing)  -> MsgGainModPow modid tkind name_loc pow
                    (Nothing,  Just pow, Just dur) -> MsgGainModPowDur modid tkind name_loc pow dur
                    (Just who, Nothing,  Nothing)  -> MsgActorGainsMod modid who tkind name_loc
                    (Just who, Nothing,  Just dur) -> MsgActorGainsModDur modid who tkind name_loc dur
                    (Just who, Just pow, Nothing)  -> MsgActorGainsModPow modid who tkind name_loc pow
                    (Just who, Just pow, Just dur) -> MsgActorGainsModPowDur modid who tkind name_loc pow dur
            _ -> preMessage stmt -- Must have mod id
    else return (preMessage stmt)
addModifier _ stmt = preStatement stmt

-- Add core

-- "add_core = <n>" in country scope means "Gain core on <localize PROVn>"
-- "add_core = <tag>" in province scope means "<localize tag> gains core"
addCore :: (IsGameData (GameData g),
            IsGameState (GameState g),
            Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
addCore (Statement _ OpEq (textRhs -> Just tag)) = msgToPP =<< do -- tag
    tagflag <- flagText tag
    return $ MsgTagGainsCore tagflag
addCore (Statement _ OpEq (floatRhs -> Just num)) = msgToPP =<< do -- province
    prov <- getProvLoc num
    return $ MsgGainCoreOnProvince prov
addCore stmt = preStatement stmt

-- Opinions

-- Add an opinion modifier towards someone (for a number of years).
data AddOpinion = AddOpinion {
        op_who :: Maybe Text
    ,   op_modifier :: Maybe Text
    ,   op_years :: Maybe Double
    } deriving Show
newAddOpinion :: AddOpinion
newAddOpinion = AddOpinion Nothing Nothing Nothing

opinion :: (IsGameData (GameData g), IsGameState (GameState g), Monad m) =>
    (Text -> Text -> ScriptMessage)
        -> (Text -> Text -> Double -> ScriptMessage)
        -> GenericStatement -> PPT g m IndentedMessages
opinion msgIndef msgDur stmt@(Statement _ OpEq (CompoundRhs scr))
    = msgToPP =<< pp_add_opinion (foldl' addLine newAddOpinion scr)
    where
        addLine :: AddOpinion -> GenericStatement -> AddOpinion
        addLine op [pdx| who      = $tag   |] = op { op_who = Just tag }
        addLine op [pdx| modifier = ?label |] = op { op_modifier = Just label }
        addLine op [pdx| years    = !n     |] = op { op_years = Just n }
        addLine op _ = op
        pp_add_opinion op = case (op_who op, op_modifier op) of
            (Just whom, Just modifier) -> do
                whomflag <- Doc.doc2text <$> flag whom
                mod_loc <- getGameL10n modifier
                case op_years op of
                    Nothing -> return $ msgIndef mod_loc whomflag
                    Just years -> return $ msgDur mod_loc whomflag years
            _ -> trace ("failed! modifier op is " ++ show (op_modifier op)) $ return (preMessage stmt)
opinion _ _ stmt = preStatement stmt

data HasOpinion = HasOpinion
        {   hop_who :: Maybe Text
        ,   hop_value :: Maybe Double
        }
newHasOpinion :: HasOpinion
newHasOpinion = HasOpinion Nothing Nothing
hasOpinion :: forall g m. (IsGameData (GameData g),
                           IsGameState (GameState g),
                           Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
hasOpinion stmt@(Statement _ OpEq (CompoundRhs scr))
    = msgToPP =<< pp_hasOpinion (foldl' addLine newHasOpinion scr)
    where
        addLine :: HasOpinion -> GenericStatement -> HasOpinion
        addLine hop [pdx| who   = ?who |] = hop { hop_who = Just who }
        addLine hop [pdx| value = !val |] = hop { hop_value = Just val }
        addLine hop _ = trace "warning: unrecognized has_opinion clause" hop
        pp_hasOpinion :: HasOpinion -> PPT g m ScriptMessage
        pp_hasOpinion hop = case (hop_who hop, hop_value hop) of
            (Just who, Just value) -> do
                who_flag <- flag who
                return (MsgHasOpinion value (Doc.doc2text who_flag))
            _ -> return (preMessage stmt)
hasOpinion stmt = preStatement stmt

-- Rebels

-- Render a rebel type atom (e.g. anti_tax_rebels) as their name and icon key.
-- This is needed because all religious rebels localize as simply "Religious" -
-- we want to be more specific.
rebel_loc :: HashMap Text (Text,Text)
rebel_loc = HM.fromList
        [("polish_noble_rebels",    ("Magnates", "magnates"))
        ,("lollard_rebels",         ("Lollard zealots", "lollards"))
        ,("catholic_rebels",        ("Catholic zealots", "catholic zealots"))
        ,("protestant_rebels",      ("Protestant zealots", "protestant zealots"))
        ,("reformed_rebels",        ("Reformed zealots", "reformed zealots"))
        ,("orthodox_rebels",        ("Orthodox zealots", "orthodox zealots"))
        ,("sunni_rebels",           ("Sunni zealots", "sunni zealots"))
        ,("shiite_rebels",          ("Shiite zealots", "shiite zealots"))
        ,("buddhism_rebels",        ("Buddhist zealots", "buddhist zealots"))
        ,("mahayana_rebels",        ("Mahayana zealots", "mahayana zealots"))
        ,("vajrayana_rebels",       ("Vajrayana zealots", "vajrayana zealots"))
        ,("hinduism_rebels",        ("Hindu zealots", "hindu zealots"))
        ,("confucianism_rebels",    ("Confucian zealots", "confucian zealots"))
        ,("shinto_rebels",          ("Shinto zealots", "shinto zealots"))
        ,("animism_rebels",         ("Animist zealots", "animist zealots"))
        ,("shamanism_rebels",       ("Shamanist zealots", "shamanist zealots"))
        ,("totemism_rebels",        ("Totemist zealots", "totemist zealots"))
        ,("coptic_rebels",          ("Coptic zealots", "coptic zealots"))
        ,("ibadi_rebels",           ("Ibadi zealots", "ibadi zealots"))
        ,("sikhism_rebels",         ("Sikh zealots", "sikh zealots"))
        ,("jewish_rebels",          ("Jewish zealots", "jewish zealots"))
        ,("norse_pagan_reformed_rebels", ("Norse zealots", "norse zealots"))
        ,("inti_rebels",            ("Inti zealots", "inti zealots"))
        ,("maya_rebels",            ("Maya zealots", "maya zealots"))
        ,("nahuatl_rebels",         ("Nahuatl zealots", "nahuatl zealots"))
        ,("tengri_pagan_reformed_rebels", ("Tengri zealots", "tengri zealots"))
        ,("zoroastrian_rebels",     ("Zoroastrian zealots", "zoroastrian zealots"))
        ,("ikko_ikki_rebels",       ("Ikko-Ikkis", "ikko-ikkis"))
        ,("ronin_rebels",           ("Ronin rebels", "ronin"))
        ,("reactionary_rebels",     ("Reactionaries", "reactionaries"))
        ,("anti_tax_rebels",        ("Peasant rabble", "peasants"))
        ,("revolutionary_rebels",   ("Revolutionaries", "revolutionaries"))
        ,("heretic_rebels",         ("Heretics", "heretics"))
        ,("religious_rebels",       ("Religious zealots", "religious zealots"))
        ,("nationalist_rebels",     ("Separatist rebels", "separatists"))
        ,("noble_rebels",           ("Noble rebels", "noble rebels"))
        ,("colonial_rebels",        ("Colonial rebels", "colonial rebels")) -- ??
        ,("patriot_rebels",         ("Patriot rebels", "patriot"))
        ,("pretender_rebels",       ("Pretender rebels", "pretender"))
        ,("colonial_patriot_rebels", ("Colonial patriot", "colonial patriot")) -- ??
        ,("particularist_rebels",   ("Particularist rebels", "particularist"))
        ,("nationalist_rebels",   ("Nationalist rebels", "separatists"))
        ]

-- Spawn a rebel stack.
data SpawnRebels = SpawnRebels {
        rebelType :: Maybe Text
    ,   rebelSize :: Maybe Double
    ,   friend :: Maybe Text
    ,   win :: Bool
    ,   sr_unrest :: Maybe Double -- rebel faction progress
    ,   sr_leader :: Maybe Text
    } deriving Show
newSpawnRebels :: SpawnRebels
newSpawnRebels = SpawnRebels Nothing Nothing Nothing False Nothing Nothing

spawnRebels :: forall g m. (IsGameData (GameData g),
                            IsGameState (GameState g),
                            Monad m) =>
    Maybe Text
        -> GenericStatement
        -> PPT g m IndentedMessages
spawnRebels mtype stmt = msgToPP =<< spawnRebels' mtype stmt where
    spawnRebels' Nothing (Statement _ OpEq (CompoundRhs scr))
        = pp_spawnRebels $ foldl' addLine newSpawnRebels scr
    spawnRebels' rtype (Statement _ OpEq (floatRhs -> Just size))
        = pp_spawnRebels $ newSpawnRebels { rebelType = rtype, rebelSize = Just size }
    spawnRebels' _ stmt' = return (preMessage stmt')

    addLine :: SpawnRebels -> GenericStatement -> SpawnRebels
    addLine op [pdx| type   = $tag  |] = op { rebelType = Just tag }
    addLine op [pdx| size   = !n    |] = op { rebelSize = Just n }
    addLine op [pdx| friend = $tag  |] = op { friend = Just tag }
    addLine op [pdx| win    = yes   |] = op { win = True }
    addLine op [pdx| unrest = !n    |] = op { sr_unrest = Just n }
    addLine op [pdx| leader = ?name |] = op { sr_leader = Just name }
    addLine op _ = op

    pp_spawnRebels :: SpawnRebels -> PPT g m ScriptMessage
    pp_spawnRebels reb
        = case rebelSize reb of
            Just size -> do
                let rtype_loc_icon = flip HM.lookup rebel_loc =<< rebelType reb
                friendText <- case friend reb of
                    Just thefriend -> do
                        cflag <- flagText thefriend
                        mtext <- messageText (MsgRebelsFriendlyTo cflag)
                        return (" (" <> mtext <> ")")
                    Nothing -> return ""
                leaderText <- case sr_leader reb of
                    Just leader -> do
                        mtext <- messageText (MsgRebelsLedBy leader)
                        return (" (" <> mtext <> ")")
                    Nothing -> return ""
                progressText <- case sr_unrest reb of
                    Just unrest -> do
                        mtext <- messageText (MsgRebelsGainProgress unrest)
                        return (" (" <> mtext <> ")")
                    Nothing -> return ""
                return $ MsgSpawnRebels
                            (maybe "" (\(ty, ty_icon) -> iconText ty_icon <> " " <> ty) rtype_loc_icon)
                            size
                            friendText
                            leaderText
                            (win reb)
                            progressText
            _ -> return $ preMessage stmt

hasSpawnedRebels :: (IsGameState (GameState g), Monad m) => GenericStatement -> PPT g m IndentedMessages
hasSpawnedRebels [pdx| %_ = $rtype |]
    | Just (rtype_loc, rtype_iconkey) <- HM.lookup rtype rebel_loc
      = msgToPP $ MsgRebelsHaveRisen (iconText rtype_iconkey) rtype_loc
hasSpawnedRebels stmt = preStatement stmt

canSpawnRebels :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
canSpawnRebels [pdx| %_ = $rtype |]
    | Just (rtype_loc, rtype_iconkey) <- HM.lookup rtype rebel_loc
      = msgToPP (MsgProvinceHasRebels (iconText rtype_iconkey) rtype_loc)
canSpawnRebels stmt = preStatement stmt

-- Events

data TriggerEvent = TriggerEvent
        { e_id :: Maybe Text
        , e_title_loc :: Maybe Text
        , e_days :: Maybe Double
        }
newTriggerEvent :: TriggerEvent
newTriggerEvent = TriggerEvent Nothing Nothing Nothing
triggerEvent :: forall g m. (EU4Info g, Monad m) =>
    ScriptMessage
        -> GenericStatement
        -> PPT g m IndentedMessages
triggerEvent evtType stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_trigger_event =<< foldM addLine newTriggerEvent scr
    where
        addLine :: TriggerEvent -> GenericStatement -> PPT g m TriggerEvent
        addLine evt [pdx| id = $eid |] = do
            mevt_t <- getEventTitle eid
            when (eid == "institution_events.25") $
                case mevt_t of
                    Nothing -> traceM ("failed to look up event id " ++ T.unpack eid)
                    Just loc -> traceM ("event id " ++ T.unpack eid ++ " is " ++ T.unpack loc)
            return evt { e_id = Just eid, e_title_loc = mevt_t }
        addLine evt [pdx| days = %rhs |]
            = return evt { e_days = floatRhs rhs }
        addLine evt _ = return evt
        pp_trigger_event :: TriggerEvent -> PPT g m ScriptMessage
        pp_trigger_event evt = do
            evtType_t <- messageText evtType
            case e_id evt of
                Just msgid ->
                    let loc = fromMaybe msgid (e_title_loc evt)
                    in case e_days evt of
                        Just days -> return $ MsgTriggerEventDays evtType_t msgid loc days
                        Nothing -> return $ MsgTriggerEvent evtType_t msgid loc
                _ -> return $ preMessage stmt
triggerEvent _ stmt = preStatement stmt

-- Specific values

gainManpower :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
gainManpower [pdx| %_ = !amt |] = msgToPP =<<
    let mpicon = iconText "manpower"
    in if abs (amt::Double) < 1
        --  interpret amt as a fraction of max
        then return $ MsgGainMPFrac mpicon amt
        --  interpret amt as a multiple of 1,000
        else return $ MsgGainMP mpicon (amt*1000)
gainManpower stmt = preStatement stmt

-- Casus belli

data AddCB = AddCB
    {   acb_target :: Maybe Text
    ,   acb_target_flag :: Maybe Text
    ,   acb_type :: Maybe Text
    ,   acb_type_loc :: Maybe Text
    ,   acb_months :: Maybe Double
    }
newAddCB :: AddCB
newAddCB = AddCB Nothing Nothing Nothing Nothing Nothing
addCB :: forall g m. (IsGameData (GameData g),
                      IsGameState (GameState g),
                      Monad m) =>
    Bool -- ^ True for add_casus_belli, False for reverse_add_casus_belli
        -> GenericStatement
        -> PPT g m IndentedMessages
addCB direct stmt@[pdx| %_ = @scr |]
    = msgToPP . pp_add_cb =<< foldM addLine newAddCB scr where
        addLine :: AddCB -> GenericStatement -> PPT g m AddCB
        addLine acb [pdx| target = $target |]
            = (\target_loc -> acb
                  { acb_target = Just target
                  , acb_target_flag = Just (Doc.doc2text target_loc) })
              <$> flag target
        addLine acb [pdx| type = $cbtype |]
            = (\cbtype_loc -> acb
                  { acb_type = Just cbtype
                  , acb_type_loc = cbtype_loc })
              <$> getGameL10nIfPresent cbtype
        addLine acb [pdx| months = %rhs |]
            = return $ acb { acb_months = floatRhs rhs }
        addLine acb _ = return acb
        pp_add_cb :: AddCB -> ScriptMessage
        pp_add_cb acb =
            let msg = if direct then MsgGainCB else MsgReverseGainCB
                msg_dur = if direct then MsgGainCBDuration else MsgReverseGainCBDuration
            in case (acb_type acb, acb_type_loc acb,
                     acb_target_flag acb,
                     acb_months acb) of
                (Nothing, _, _, _) -> preMessage stmt -- need CB type
                (_, _, Nothing, _) -> preMessage stmt -- need target
                (_, Just cbtype_loc, Just target_flag, Just months) -> msg_dur cbtype_loc target_flag months
                (Just cbtype, Nothing, Just target_flag, Just months) -> msg_dur cbtype target_flag months
                (_, Just cbtype_loc, Just target_flag, Nothing) -> msg cbtype_loc target_flag
                (Just cbtype, Nothing, Just target_flag, Nothing) -> msg cbtype target_flag
addCB _ stmt = preStatement stmt

-- Random

random :: (EU4Info g, Monad m) => GenericStatement -> PPT g m IndentedMessages
random stmt@[pdx| %_ = @scr |]
    | (front, back) <- break
                        (\substmt -> case substmt of
                            [pdx| chance = %_ |] -> True
                            _ -> False)
                        scr
      , not (null back)
      , [pdx| %_ = %rhs |] <- head back
      , Just chance <- floatRhs rhs
      = compoundMessage
          (MsgRandomChance chance)
          [pdx| %undefined = @(front ++ tail back) |]
    | otherwise = compoundMessage MsgRandom stmt
random stmt = preStatement stmt

-- Advisors

data DefineAdvisor = DefineAdvisor
    {   da_type :: Maybe Text
    ,   da_type_loc :: Maybe Text
    ,   da_name :: Maybe Text
    ,   da_discount :: Maybe Bool
    ,   da_location :: Maybe Int
    ,   da_location_loc :: Maybe Text
    ,   da_skill :: Maybe Double
    ,   da_female :: Maybe Bool
    }
newDefineAdvisor :: DefineAdvisor
newDefineAdvisor = DefineAdvisor Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

defineAdvisor :: forall g m. (IsGameData (GameData g),
                              IsGameState (GameState g),
                              Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
defineAdvisor stmt@[pdx| %_ = @scr |]
    = msgToPP . pp_define_advisor =<< foldM addLine newDefineAdvisor scr where
        addLine :: DefineAdvisor -> GenericStatement -> PPT g m DefineAdvisor
        addLine da [pdx| $lhs = %rhs |] = case T.map toLower lhs of
            "type" ->
                let mthe_type = case rhs of
                        GenericRhs a_type -> Just a_type
                        StringRhs a_type -> Just a_type
                        _ -> Nothing
                in (\mtype_loc -> da
                        { da_type = mthe_type
                        , da_type_loc = mtype_loc })
                   <$> maybe (return Nothing) getGameL10nIfPresent mthe_type
            "name" -> return $
                let mthe_name = case rhs of
                        GenericRhs a_name -> Just a_name
                        StringRhs a_name -> Just a_name
                        _ -> Nothing
                in da { da_name = mthe_name }
            "discount" -> return $
                let yn = case rhs of
                        GenericRhs yn' -> Just yn'
                        StringRhs yn' -> Just yn'
                        _ -> Nothing
                in if yn == Just "yes" then da { da_discount = Just True }
                   else if yn == Just "no" then da { da_discount = Just False }
                   else da
            "location" -> do
                let location_code = floatRhs rhs
                location_loc <- sequence (getProvLoc <$> location_code)
                return $ da { da_location = location_code
                            , da_location_loc = location_loc }
            "skill" -> return $ da { da_skill = floatRhs rhs }
            "female" -> return $
                let yn = case rhs of
                        GenericRhs yn' -> Just yn'
                        StringRhs yn' -> Just yn'
                        _ -> Nothing
                in if yn == Just "yes" then da { da_female = Just True }
                   else if yn == Just "no" then da { da_female = Just False }
                   else da
            _ -> return da
        addLine da _ = return da
        pp_define_advisor :: DefineAdvisor -> ScriptMessage
        pp_define_advisor da =
            case da_skill da of
                Just skill ->
                    let mdiscount = da_discount da
                        discount = fromMaybe False mdiscount
                        mlocation_loc = da_location_loc da
                        mlocation = mlocation_loc `mplus` (T.pack . show <$> da_location da)
                    in case (da_female da,
                               da_type_loc da,
                               da_name da,
                               mlocation) of
                        (Nothing, Nothing, Nothing, Nothing)
                            -> (if discount then MsgGainAdvisorDiscount else MsgGainAdvisor) skill
                        (Nothing, Nothing, Nothing, Just location)
                            -> (if discount then MsgGainAdvisorLocDiscount else MsgGainAdvisorLoc)
                                location skill
                        (Nothing, Nothing, Just name, Nothing)
                            -> (if discount then MsgGainAdvisorNameDiscount else MsgGainAdvisorName)
                                name skill
                        (Nothing, Nothing, Just name, Just location)
                            -> (if discount then MsgGainAdvisorNameLocDiscount else MsgGainAdvisorNameLoc)
                                name location skill
                        (Nothing, Just advtype, Nothing, Nothing)
                            -> (if discount then MsgGainAdvisorTypeDiscount else MsgGainAdvisorType)
                                advtype skill
                        (Nothing, Just advtype, Nothing, Just location)
                            -> (if discount then MsgGainAdvisorTypeLocDiscount else MsgGainAdvisorTypeLoc)
                                advtype location skill
                        (Nothing, Just advtype, Just name, Nothing)
                            -> (if discount then MsgGainAdvisorTypeNameDiscount else MsgGainAdvisorTypeName)
                                advtype name skill
                        (Nothing, Just advtype, Just name, Just location)
                            -> (if discount then MsgGainAdvisorTypeNameLocDiscount else MsgGainAdvisorTypeNameLoc)
                                advtype name location skill
                        (Just female, Nothing, Nothing, Nothing)
                            -> (if discount then MsgGainFemaleAdvisorDiscount else MsgGainFemaleAdvisor)
                                female skill
                        (Just female, Nothing, Nothing, Just location)
                            -> (if discount then MsgGainFemaleAdvisorLocDiscount else MsgGainFemaleAdvisorLoc)
                                female location skill
                        (Just female, Nothing, Just name, Nothing)
                            -> (if discount then MsgGainFemaleAdvisorNameDiscount else MsgGainFemaleAdvisorName)
                                female name skill
                        (Just female, Nothing, Just name, Just location)
                            -> (if discount then MsgGainFemaleAdvisorNameLocDiscount else MsgGainFemaleAdvisorNameLoc)
                                female name location skill
                        (Just female, Just advtype, Nothing, Nothing)
                            -> (if discount then MsgGainFemaleAdvisorTypeDiscount else MsgGainFemaleAdvisorType)
                                female advtype skill
                        (Just female, Just advtype, Nothing, Just location)
                            -> (if discount then MsgGainFemaleAdvisorTypeLocDiscount else MsgGainFemaleAdvisorTypeLoc)
                                female advtype location skill
                        (Just female, Just advtype, Just name, Nothing)
                            -> (if discount then MsgGainFemaleAdvisorTypeNameDiscount else MsgGainFemaleAdvisorTypeName)
                                female advtype name skill
                        (Just female, Just advtype, Just name, Just location)
                            -> (if discount then MsgGainFemaleAdvisorTypeNameLocDiscount else MsgGainFemaleAdvisorTypeNameLoc)
                                female advtype name location skill
                _ -> preMessage stmt
defineAdvisor stmt = preStatement stmt

-- Rulers

data DefineRuler = DefineRuler
    {   dr_rebel :: Bool
    ,   dr_name :: Maybe Text
    ,   dr_dynasty :: Maybe Text -- can be a tag/pronoun
    ,   dr_age :: Maybe Double
    ,   dr_female :: Maybe Bool
    ,   dr_claim :: Maybe Double
    ,   dr_regency :: Bool
    ,   dr_adm :: Maybe Int
    ,   dr_dip :: Maybe Int
    ,   dr_mil :: Maybe Int
    ,   dr_fixed :: Bool
    ,   dr_attach_leader :: Maybe Text
    }
newDefineRuler :: DefineRuler
newDefineRuler = DefineRuler False Nothing Nothing Nothing Nothing Nothing False Nothing Nothing Nothing False Nothing

defineRuler :: forall g m. (IsGameState (GameState g), Monad m) => GenericStatement -> PPT g m IndentedMessages
defineRuler [pdx| %_ = @scr |]
    = pp_define_ruler $ foldl' addLine newDefineRuler scr where
        addLine :: DefineRuler -> GenericStatement -> DefineRuler
        addLine dr [pdx| $lhs = %rhs |] = case T.map toLower lhs of
            "rebel" -> case textRhs rhs of
                Just "yes" -> dr { dr_rebel = True }
                _ -> dr
            "name" -> dr { dr_name = textRhs rhs }
            "dynasty" -> dr { dr_dynasty = textRhs rhs }
            "age" -> dr { dr_age = floatRhs rhs }
            "female" -> case textRhs rhs of
                Just "yes" -> dr { dr_female = Just True }
                Just "no"  -> dr { dr_female = Just False }
                _ -> dr
            "claim" -> dr { dr_claim = floatRhs rhs }
            "regency" -> case textRhs rhs of
                Just "yes" -> dr { dr_regency = True }
                _ -> dr
            "adm" -> dr { dr_adm = floatRhs rhs }
            "dip" -> dr { dr_dip = floatRhs rhs }
            "mil" -> dr { dr_mil = floatRhs rhs }
            "fixed" -> case textRhs rhs of
                Just "yes" -> dr { dr_fixed = True }
                _ -> dr
            "attach_leader" -> dr { dr_attach_leader = textRhs rhs }
            _ -> dr
        addLine dr _ = dr
        pp_define_ruler :: DefineRuler -> PPT g m IndentedMessages
        pp_define_ruler    DefineRuler { dr_rebel = True } = msgToPP MsgRebelLeaderRuler
        pp_define_ruler dr@DefineRuler { dr_regency = regency, dr_attach_leader = mleader } = do
            body <- indentUp (unfoldM pp_define_ruler_attrib dr)
            if null body then
                msgToPP (maybe (MsgNewRuler regency) (MsgNewRulerLeader regency) mleader)
            else
                liftA2 (++)
                    (msgToPP (maybe (MsgNewRulerAttribs regency) (MsgNewRulerLeaderAttribs regency) mleader))
                    (pure body)
        pp_define_ruler_attrib :: DefineRuler -> PPT g m (Maybe (IndentedMessage, DefineRuler))
        -- "Named <foo>"
        pp_define_ruler_attrib dr@DefineRuler { dr_name = Just name } = do
            [msg] <- msgToPP (MsgNewRulerName name)
            return (Just (msg, dr { dr_name = Nothing }))
        -- "Of the <foo> dynasty"
        pp_define_ruler_attrib dr@DefineRuler { dr_dynasty = Just dynasty } = do
            [msg] <- msgToPP (MsgNewRulerDynasty dynasty)
            return (Just (msg, dr { dr_dynasty = Nothing }))
        -- "Aged <foo> years"
        pp_define_ruler_attrib dr@DefineRuler { dr_age = Just age } = do
            [msg] <- msgToPP (MsgNewRulerAge age)
            return (Just (msg, dr { dr_age = Nothing }))
        -- "With {{icon|adm}} <foo> administrative skill"
        pp_define_ruler_attrib dr@DefineRuler { dr_adm = Just adm, dr_fixed = fixed } = do
            [msg] <- msgToPP (MsgNewRulerAdm fixed (fromIntegral adm))
            return (Just (msg, dr { dr_adm = Nothing }))
        -- "With {{icon|adm}} <foo> diplomatic skill"
        pp_define_ruler_attrib dr@DefineRuler { dr_dip = Just dip, dr_fixed = fixed } = do
            [msg] <- msgToPP (MsgNewRulerDip fixed (fromIntegral dip))
            return (Just (msg, dr { dr_dip = Nothing }))
        -- "With {{icon|adm}} <foo> military skill"
        pp_define_ruler_attrib dr@DefineRuler { dr_mil = Just mil, dr_fixed = fixed } = do
            [msg] <- msgToPP (MsgNewRulerMil fixed (fromIntegral mil))
            return (Just (msg, dr { dr_mil = Nothing }))
        -- Nothing left
        pp_define_ruler_attrib _ = return Nothing
defineRuler stmt = preStatement stmt

-- Building units

data BuildToForcelimit = BuildToForcelimit
    {   btf_infantry :: Maybe Double
    ,   btf_cavalry :: Maybe Double
    ,   btf_artillery :: Maybe Double
    ,   btf_heavy_ship :: Maybe Double
    ,   btf_light_ship :: Maybe Double
    ,   btf_galley :: Maybe Double
    ,   btf_transport :: Maybe Double
    }
newBuildToForcelimit :: BuildToForcelimit
newBuildToForcelimit = BuildToForcelimit Nothing Nothing Nothing Nothing Nothing Nothing Nothing

buildToForcelimit :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
buildToForcelimit stmt@[pdx| %_ = @scr |]
    = msgToPP . pp_build_to_forcelimit $ foldl' addLine newBuildToForcelimit scr where
        addLine :: BuildToForcelimit -> GenericStatement -> BuildToForcelimit
        addLine dr [pdx| $lhs = !howmuch |]
            = case T.map toLower lhs of
                "infantry"   -> dr { btf_infantry   = Just howmuch }
                "cavalry"    -> dr { btf_cavalry    = Just howmuch }
                "artillery"  -> dr { btf_artillery  = Just howmuch }
                "heavy_ship" -> dr { btf_heavy_ship = Just howmuch }
                "light_ship" -> dr { btf_light_ship = Just howmuch }
                "galley"     -> dr { btf_galley     = Just howmuch }
                "transport"  -> dr { btf_transport  = Just howmuch }
                _ -> dr
        addLine dr _ = dr
        pp_build_to_forcelimit :: BuildToForcelimit -> ScriptMessage
        pp_build_to_forcelimit dr =
            let has_infantry = isJust (btf_infantry dr)
                has_cavalry = isJust (btf_cavalry dr)
                has_artillery = isJust (btf_artillery dr)
                has_heavy_ship = isJust (btf_heavy_ship dr)
                has_light_ship = isJust (btf_light_ship dr)
                has_galley = isJust (btf_galley dr)
                has_transport = isJust (btf_transport dr)
                infantry = fromMaybe 0 (btf_infantry dr)
                cavalry = fromMaybe 0 (btf_cavalry dr)
                artillery = fromMaybe 0 (btf_artillery dr)
                heavy_ship = fromMaybe 0 (btf_heavy_ship dr)
                light_ship = fromMaybe 0 (btf_light_ship dr)
                galley = fromMaybe 0 (btf_galley dr)
                transport = fromMaybe 0 (btf_transport dr)
                has_land = has_infantry || has_cavalry || has_artillery
                has_navy = has_heavy_ship || has_light_ship || has_galley || has_transport
            in  if has_land == has_navy then
                    -- Neither or both. Unlikely, not provided for
                    preMessage stmt
                else if has_land then let
                    infIcon = iconText "infantry"
                    cavIcon = iconText "cavalry"
                    artIcon = iconText "artillery"
                    in MsgBuildToForcelimitLand infIcon infantry
                                                cavIcon cavalry
                                                artIcon artillery
                else let -- has_navy == True
                    heavyIcon = iconText "heavy ship"
                    lightIcon = iconText "light ship"
                    gallIcon = iconText "galley"
                    transpIcon = iconText "transport"
                    in MsgBuildToForcelimitNavy heavyIcon heavy_ship
                                                lightIcon light_ship
                                                gallIcon galley
                                                transpIcon transport
buildToForcelimit stmt = preStatement stmt

-- War

data DeclareWarWithCB = DeclareWarWithCB
    {   dwcb_who :: Maybe Text
    ,   dwcb_cb :: Maybe Text
    }
newDeclareWarWithCB :: DeclareWarWithCB
newDeclareWarWithCB = DeclareWarWithCB Nothing Nothing

declareWarWithCB :: forall g m. (IsGameData (GameData g),
                                 IsGameState (GameState g),
                                 Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
declareWarWithCB stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_declare_war_with_cb (foldl' addLine newDeclareWarWithCB scr) where
        addLine :: DeclareWarWithCB -> GenericStatement -> DeclareWarWithCB
        addLine dwcb [pdx| $lhs = $rhs |]
            = case T.map toLower lhs of
                "who"         -> dwcb { dwcb_who = Just rhs }
                "casus_belli" -> dwcb { dwcb_cb  = Just rhs }
                _ -> dwcb
        addLine dwcb _ = dwcb
        pp_declare_war_with_cb :: DeclareWarWithCB -> PPT g m ScriptMessage
        pp_declare_war_with_cb dwcb
              = case (dwcb_who dwcb, dwcb_cb dwcb) of
                (Just who, Just cb) -> do
                    whoflag <- Doc.doc2text <$> flag who
                    cb_loc <- getGameL10n cb
                    return (MsgDeclareWarWithCB whoflag cb_loc)
                _ -> return $ preMessage stmt
declareWarWithCB stmt = preStatement stmt

-- DLC

hasDlc :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
hasDlc [pdx| %_ = ?dlc |]
    = msgToPP $ MsgHasDLC dlc_icon dlc
    where
        mdlc_key = HM.lookup dlc . HM.fromList $
            [("Conquest of Paradise", "cop")
            ,("Wealth of Nations", "won")
            ,("Res Publica", "rp")
            ,("Art of War", "aow")
            ,("El Dorado", "ed")
            ,("Common Sense", "cs")
            ,("The Cossacks", "cos")
            ,("Mare Nostrum", "mn")
            ,("Rights of Man", "rom")
            ,("Mandate of Heaven", "moh")
            ,("Third Rome", "tr")
            ,("Cradle of Civilization", "coc")
            ]
        dlc_icon = maybe "" iconText mdlc_key
hasDlc stmt = preStatement stmt

-- Estates

data EstateInfluenceModifier = EstateInfluenceModifier {
        eim_estate :: Maybe Text
    ,   eim_modifier :: Maybe Text
    }
newEIM :: EstateInfluenceModifier
newEIM = EstateInfluenceModifier Nothing Nothing
hasEstateInfluenceModifier :: (IsGameData (GameData g),
                               IsGameState (GameState g),
                               Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
hasEstateInfluenceModifier stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_eim (foldl' addField newEIM scr)
    where
        addField :: EstateInfluenceModifier -> GenericStatement -> EstateInfluenceModifier
        addField inf [pdx| estate   = $est      |] = inf { eim_estate = Just est }
        addField inf [pdx| modifier = $modifier |] = inf { eim_modifier = Just modifier }
        addField inf _ = inf -- unknown statement
        pp_eim inf = case (eim_estate inf, eim_modifier inf) of
            (Just est, Just modifier) -> do
                loc_est <- getGameL10n est
                loc_mod <- getGameL10n modifier
                return $ MsgEstateHasInfluenceModifier (iconText est) loc_est loc_mod
            _ -> return (preMessage stmt)
hasEstateInfluenceModifier stmt = preStatement stmt

data AddEstateInfluenceModifier = AddEstateInfluenceModifier {
        aeim_estate :: Maybe Text
    ,   aeim_desc :: Maybe Text
    ,   aeim_influence :: Maybe Double
    ,   aeim_duration :: Maybe Double
    } deriving Show
newAddEstateInfluenceModifier :: AddEstateInfluenceModifier
newAddEstateInfluenceModifier = AddEstateInfluenceModifier Nothing Nothing Nothing Nothing

timeOrIndef :: (IsGameData (GameData g), Monad m) => Double -> PPT g m Text
timeOrIndef n = if n < 0 then messageText MsgIndefinitely else messageText (MsgForDays n)

estateInfluenceModifier :: forall g m. (IsGameData (GameData g),
                                        IsGameState (GameState g),
                                        Monad m) =>
    (Text -> Text -> Text -> Double -> Text -> ScriptMessage)
        -> GenericStatement -> PPT g m IndentedMessages
estateInfluenceModifier msg stmt@[pdx| %_ = @scr |]
    = msgToPP =<< pp_eim (foldl' addLine newAddEstateInfluenceModifier scr)
    where
        addLine :: AddEstateInfluenceModifier -> GenericStatement -> AddEstateInfluenceModifier
        addLine aeim [pdx| estate    = $estate   |] = aeim { aeim_estate = Just estate }
        addLine aeim [pdx| desc      = $desc     |] = aeim { aeim_desc = Just desc }
        addLine aeim [pdx| influence = !inf      |] = aeim { aeim_influence = Just inf }
        addLine aeim [pdx| duration  = !duration |] = aeim { aeim_duration = Just duration }
        addLine aeim _ = aeim
        pp_eim :: AddEstateInfluenceModifier -> PPT g m ScriptMessage
        pp_eim aeim
            = case (aeim_estate aeim, aeim_desc aeim, aeim_influence aeim, aeim_duration aeim) of
                (Just estate, Just desc, Just inf, Just duration) -> do
                    let estate_icon = iconText estate
                    estate_loc <- getGameL10n estate
                    desc_loc <- getGameL10n desc
                    dur <- timeOrIndef duration
                    return (msg estate_icon estate_loc desc_loc inf dur)
                _ -> return (preMessage stmt)
estateInfluenceModifier _ stmt = preStatement stmt

-- Trigger switch

triggerSwitch :: (EU4Info g, Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
-- A trigger switch must be of the form
-- trigger_switch = {
--  on_trigger = <statement lhs>
--  <statement rhs> = {
--      <actions>
--  }
-- }
-- where the <statement rhs> block may be repeated several times.
triggerSwitch stmt@(Statement _ OpEq (CompoundRhs
                    ([pdx| on_trigger = $condlhs |] -- assume this is first statement
                    :clauses))) = do
            statementsMsgs <- indentUp $ forM clauses $ \clause -> case clause of
                -- using next indent level, for each block <condrhs> = { ... }:
                [pdx| $condrhs = @action |] -> do
                    -- construct a fake condition to pp
                    let cond = [pdx| $condlhs = $condrhs |]
                    ((_, guardMsg):_) <- ppOne cond -- XXX: match may fail (but shouldn't)
                    guardText <- messageText guardMsg
                    -- pp the rest of the block, at the next level
                    statementMsgs <- indentUp (ppMany action)
                    withCurrentIndent $ \i -> return $ (i, MsgTriggerSwitchClause guardText) : statementMsgs
                _ -> preStatement stmt
            withCurrentIndent $ \i -> return $ (i, MsgTriggerSwitch) : concat statementsMsgs
triggerSwitch stmt = preStatement stmt

-- Heirs

data Heir = Heir
        {   heir_dynasty :: Maybe Text
        ,   heir_claim :: Maybe Double
        ,   heir_age :: Maybe Double
        }
newHeir :: Heir
newHeir = Heir Nothing Nothing Nothing
defineHeir :: forall g m. (IsGameData (GameData g),
                           IsGameState (GameState g),
                           Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
defineHeir [pdx| %_ = @scr |]
    = msgToPP =<< pp_heir (foldl' addLine newHeir scr)
    where
        addLine :: Heir -> GenericStatement -> Heir
        addLine heir [pdx| dynasty = $dynasty |] = heir { heir_dynasty = Just dynasty }
        addLine heir [pdx| claim   = !claim   |] = heir { heir_claim = Just claim }
        addLine heir [pdx| age     = !age     |] = heir { heir_age = Just age }
        addLine heir _ = heir
        pp_heir :: IsGameData (GameData g) => Heir -> PPT g m ScriptMessage
        pp_heir heir = do
            dynasty_flag <- fmap Doc.doc2text <$> maybeM flag (heir_dynasty heir)
            case (heir_age heir, dynasty_flag, heir_claim heir) of
                (Nothing,  Nothing,   Nothing)     -> return $ MsgNewHeir
                (Nothing,  Nothing,   Just claim)  -> return $ MsgNewHeirClaim claim
                (Nothing,  Just cflag, Nothing)     -> return $ MsgNewHeirDynasty cflag
                (Nothing,  Just cflag, Just claim)  -> return $ MsgNewHeirDynastyClaim cflag claim
                (Just age, Nothing,   Nothing)     -> return $ MsgNewHeirAge age
                (Just age, Nothing,   Just claim)  -> return $ MsgNewHeirAgeClaim age claim
                (Just age, Just cflag, Nothing)    -> return $ MsgNewHeirAgeFlag age cflag
                (Just age, Just cflag, Just claim) -> return $ MsgNewHeirAgeFlagClaim age cflag claim
defineHeir stmt = preStatement stmt

-- Holy Roman Empire

-- Assume 1 <= n <= 8
hreReformLoc :: (IsGameData (GameData g), Monad m) => Int -> PPT g m Text
hreReformLoc n = getGameL10n $ case n of
    1 -> "reichsreform_title"
    2 -> "reichsregiment_title"
    3 -> "hofgericht_title"
    4 -> "gemeinerpfennig_title"
    5 -> "landfriede_title"
    6 -> "erbkaisertum_title"
    7 -> "privilegia_de_non_appelando_title"
    8 -> "renovatio_title"
    _ -> error "called hreReformLoc with n < 1 or n > 8"

hreReformLevel :: (IsGameData (GameData g),
                   IsGameState (GameState g),
                   Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
hreReformLevel [pdx| %_ = !level |] | level >= 0, level <= 8
    = if level == 0
        then msgToPP MsgNoHREReforms
        else msgToPP . MsgHREPassedReform =<< hreReformLoc level
hreReformLevel stmt = preStatement stmt

-- Religion

religionYears :: (IsGameData (GameData g),
                  IsGameState (GameState g),
                  Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
religionYears [pdx| %_ = { $rel = !years } |]
    = do
        let rel_icon = iconText rel
        rel_loc <- getGameL10n rel
        msgToPP $ MsgReligionYears rel_icon rel_loc years
religionYears stmt = preStatement stmt

-- Government

govtRank :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
govtRank [pdx| %_ = !level |]
    = case level :: Int of
        1 -> msgToPP MsgRankDuchy -- unlikely, but account for it anyway
        2 -> msgToPP MsgRankKingdom
        3 -> msgToPP MsgRankEmpire
        _ -> error "impossible: govtRank matched an invalid rank number"
govtRank stmt = preStatement stmt

setGovtRank :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
setGovtRank [pdx| %_ = !level |] | level `elem` [1..3]
    = case level :: Int of
        1 -> msgToPP MsgSetRankDuchy
        2 -> msgToPP MsgSetRankKingdom
        3 -> msgToPP MsgSetRankEmpire
        _ -> error "impossible: setGovtRank matched an invalid rank number"
setGovtRank stmt = preStatement stmt

numProvinces :: (IsGameData (GameData g),
                 IsGameState (GameState g),
                 Monad m) =>
    Text
        -> (Text -> Text -> Double -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
numProvinces micon msg [pdx| $what = !amt |] = do
    what_loc <- getGameL10n what
    msgToPP (msg (iconText micon) what_loc amt)
numProvinces _ _ stmt = preStatement stmt

withFlagOrProvince :: (IsGameData (GameData g),
                       IsGameState (GameState g),
                       Monad m) =>
    (Text -> ScriptMessage)
        -> (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withFlagOrProvince countryMsg _ stmt@[pdx| %_ = ?_ |]
    = withFlag countryMsg stmt
withFlagOrProvince _ provinceMsg stmt@[pdx| %_ = !(_ :: Double) |]
    = withProvince provinceMsg stmt
withFlagOrProvince _ _ stmt = preStatement stmt

withFlagOrProvinceEU4Scope :: (EU4Info g, Monad m) =>
    (Text -> ScriptMessage)
        -> (Text -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
withFlagOrProvinceEU4Scope countryMsg geogMsg stmt = do
    mscope <- getCurrentScope
    -- If no scope, assume country.
    if fromMaybe False (isGeographic <$> mscope) then
        -- RHS is tag or pronoun - "Has been discovered by <whom>"
        withFlag geogMsg stmt
    else
        -- RHS is tag, pronoun or province ID
        -- Current usages (i.e. has_discovered) treat them all the same.
        withFlagOrProvince countryMsg countryMsg stmt

tradeMod :: (IsGameData (GameData g),
             IsGameState (GameState g),
             Monad m) => GenericStatement -> PPT g m IndentedMessages
tradeMod stmt@[pdx| %_ = ?_ |]
    = withLocAtom2 MsgTradeMod MsgHasModifier stmt
tradeMod stmt@[pdx| %_ = @_ |]
    = textAtom "who" "name" MsgHasTradeModifier (fmap Just . flagText) stmt
tradeMod stmt = preStatement stmt

isMonth :: (IsGameData (GameData g),
            IsGameState (GameState g),
            Monad m) => GenericStatement -> PPT g m IndentedMessages
isMonth [pdx| %_ = !(num :: Int) |] | num >= 1, num <= 12
    = do
        month_loc <- getGameL10n $ case num of
            1 -> "January"
            2 -> "February"
            3 -> "March"
            4 -> "April"
            5 -> "May"
            6 -> "June"
            7 -> "July"
            8 -> "August"
            9 -> "September"
            10 -> "October"
            11 -> "November"
            12 -> "December"
            _ -> error "impossible: tried to localize bad month number"
        msgToPP $ MsgIsMonth month_loc
isMonth stmt = preStatement stmt

range :: (IsGameData (GameData g),
          IsGameState (GameState g),
          Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
range stmt@[pdx| %_ = !(_ :: Double) |]
    = numericIcon "colonial range" MsgGainColonialRange stmt
range stmt = withFlag MsgIsInColonialRange stmt

area :: (EU4Info g, Monad m) => GenericStatement -> PPT g m IndentedMessages
area stmt@[pdx| %_ = @_ |] = compoundMessage MsgArea stmt
area stmt                  = withLocAtom MsgAreaIs stmt

-- Currently dominant_culture only appears in decisions/Cultural.txt
-- (dominant_culture = capital).
dominantCulture :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
dominantCulture [pdx| %_ = capital |] = msgToPP MsgCapitalCultureDominant
dominantCulture stmt = preStatement stmt

customTriggerTooltip :: (EU4Info g, Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
customTriggerTooltip [pdx| %_ = @scr |]
    -- ignore the custom tooltip
    = let rest = flip filter scr $ \stmt -> case stmt of
            [pdx| tooltip = %_ |] -> False
            _ -> True
      in indentDown $ ppMany rest
customTriggerTooltip stmt = preStatement stmt

piety :: (IsGameState (GameState g), Monad m) =>
    GenericStatement -> PPT g m IndentedMessages
piety stmt@[pdx| %_ = !amt |]
    = numericIcon (case amt `compare` (0::Double) of
        LT -> "lack of piety"
        _  -> "being pious")
      MsgPiety stmt
piety stmt = preStatement stmt

----------------------
-- Idea group ideas --
----------------------

hasIdea :: (EU4Info g, Monad m) =>
    (Text -> Int -> ScriptMessage)
        -> GenericStatement
        -> PPT g m IndentedMessages
hasIdea msg stmt@[pdx| $lhs = !n |] | n >= 1, n <= 7 = do
    groupTable <- getIdeaGroups
    let mideagroup = HM.lookup lhs groupTable
    case mideagroup of
        Nothing -> preStatement stmt -- unknown idea group
        Just grp -> do
            let idea = ig_ideas grp !! (n - 1)
                ideaKey = idea_name idea
            idea_loc <- getGameL10n ideaKey
            msgToPP (msg idea_loc n)
hasIdea _ stmt = preStatement stmt
