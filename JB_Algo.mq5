//+------------------------------------------------------------------+
//| JB-Algo.mq5                                                      |
//| Jimuel Belmonte                                                  |
//| VERSION 5.36 — Market Watch panel (manual ON)                    |
//+------------------------------------------------------------------+
//
//  FULL CHANGE HISTORY (compile-fixes → v5.36):
//
//  [v5.33 ERR-1] FindFVGSlot: removed illegal MQL5 ternary array ref.
//  [v5.33 ERR-2] DetectNewFVG: replaced ternary array ref with if/else.
//  [v5.33 WARN]  IsPartialDone/IsBreakevenDone: uint→int for ArraySize().
//
//  [v5.34 FIX-A] StochD_Confirm periodic guard.
//    Every 50 bars after warmup, if StochD_Confirm=true, logs CRITICAL
//    alert so the setting cannot silently block all trades.
//
//  [v5.34 FIX-B] BB Proximity Gate for confidence score.
//    Confirmed from log 20260405: 33 SELL signals suggested when price
//    was 1.6–6.6×ATR below BB-upper (K=100 uptrend, wrong direction).
//    Fix: if price is more than BB_ConfGateDistATR×ATR from the relevant
//    band, confidence is capped at BB_ConfGateCap (default 55%, below
//    the 65% icon threshold). Set BB_ConfGateDistATR=0 to disable.
//
//  [v5.35 FIX-C] Swing High / Low Level Detection + Confluence Bonus.
//    Why: SAR/ADX tell you direction. FVGs give price-gap structure.
//    But nothing in the EA knew WHERE price was likely to reject.
//    A swing high is the most natural resistance level in price action.
//    A swing low is the most natural support level.
//
//    Implementation:
//    — Scans the last SwingLookback bars on each side (default 5) to
//      identify confirmed swing highs and lows on the current TF.
//    — Stores the most recent SwingMaxLevels (default 10) of each.
//    — IsNearSwingHigh(close,atr): true if price within
//      SwingProximityATR×ATR of a stored swing high (sell confluence).
//    — IsNearSwingLow(close,atr):  true if price within
//      SwingProximityATR×ATR of a stored swing low (buy confluence).
//    — Adds SwingLevel_ConfBonus (default 10.0) to confidence score
//      when in proximity, same pattern as FVG_ConfBonus and HTF_FVG_ConfBonus.
//    — Draws dashed horizontal lines for each swing level on the chart
//      (ShowSwingLevels=true, default). Swing highs = SellIconColor
//      tint, swing lows = BuyIconColor tint. Lines extend SwingLineExtend
//      bars (default 80) from the swing point rightward.
//    — ShowSwingLevels=false disables drawing (no chart noise in live).
//    — SwingLookback, SwingProximityATR, SwingMaxLevels, SwingLevel_ConfBonus
//      are all tunable inputs in the new "══ Swing Levels ══" group.
//
//  [v5.36] Market Watch strip under MANUAL/TRAILING when MANUAL: ON
//    (!g_TradingPaused). Live bid/ask, spread, swap, D1 hi/lo, volume
//    editor with +/- , one-click SELL/BUY using same SL/TP logic as OpenTrade.
//
//  [v5.35 FIX-D] Clean Visuals for Backtesting.
//    — Swing lines don't draw in Strategy Tester (FVG stays visible)
//    — Periodic cleanup removes old objects every 100 bars
//    — Limits visible objects to prevent chart clutter
//    — Swing visuals respect MQL_TESTER flag
//
//  All v5.34 features fully retained.
//
//+------------------------------------------------------------------+
#property copyright "Jimuel Belmonte"
#property link      ""
#property version   "5.36"
#property description "JB-Algo v5.36 | Market Watch panel + Swing H/L | Exness MT5"

#include <Trade\Trade.mqh>
CTrade trade;

//===================================================================
// SYMBOL CLASS
//===================================================================
enum ENUM_SYMBOL_CLASS
{
   SYMCLASS_FOREX = 0,
   SYMCLASS_METALS = 1,
   SYMCLASS_CRYPTO = 2,
   SYMCLASS_INDICES = 3,
   SYMCLASS_ENERGY = 4,
   SYMCLASS_UNKNOWN = 5,
   SYMCLASS_STOCKS = 6
};
string SYMCLASS_NAMES[] = {"Forex","Metals","Crypto","Indices","Energy","Unknown","Stocks"};

//===================================================================
// FVG STRUCTURE
//===================================================================
struct FVGData
{
   datetime midTime;
   double top;
   double bottom;
   double retestPrice;
   bool isBull;
   bool mitigated;
   bool active;
};
#define FVG_MAX 60
#define FVG_DISPLAY_MAX 8
FVGData g_FVGs[FVG_MAX];
FVGData g_FVGs_HTF[FVG_MAX];
int g_FVGCount = 0;
int g_FVGCount_HTF = 0;

struct OBData
{
   datetime barTime;
   double top;
   double bottom;
   bool isBull;
   bool mitigated;
   bool active;
};
#define OB_MAX 20
OBData g_OBs[OB_MAX];
OBData g_OBs_HTF[OB_MAX];
int g_OBCount = 0;
int g_OBCount_HTF = 0;
#define OBJ_PFX "JBFX_"
double g_LastATR = 0.0;

//===================================================================
// SWING HIGH / LOW STORAGE  [v5.35]
//===================================================================
#define SWING_MAX 10
struct SwingLevel
{
   double   price;      // the swing high or swing low price
   datetime barTime;    // time of the bar that formed the swing
   bool     active;     // still valid (not overridden by newer bar)
};
SwingLevel g_SwingHighs[SWING_MAX];
SwingLevel g_SwingLows [SWING_MAX];
int g_SwingHighCount = 0;
int g_SwingLowCount  = 0;
datetime g_LastSwingDetectBar = 0;  // throttle: only scan once per new bar

void ResetFVGArray()
{
   for(int i = 0; i < FVG_MAX; i++)
   {
      g_FVGs[i].midTime = 0;
      g_FVGs[i].top = 0.0;
      g_FVGs[i].bottom = 0.0;
      g_FVGs[i].retestPrice = 0.0;
      g_FVGs[i].isBull = false;
      g_FVGs[i].mitigated = false;
      g_FVGs[i].active = false;

      g_FVGs_HTF[i].midTime = 0;
      g_FVGs_HTF[i].top = 0.0;
      g_FVGs_HTF[i].bottom = 0.0;
      g_FVGs_HTF[i].retestPrice = 0.0;
      g_FVGs_HTF[i].isBull = false;
      g_FVGs_HTF[i].mitigated = false;
      g_FVGs_HTF[i].active = false;
   }
}

void ResetOBArray()
{
   for(int i = 0; i < OB_MAX; i++)
   {
      g_OBs[i].barTime = 0;
      g_OBs[i].top = 0.0;
      g_OBs[i].bottom = 0.0;
      g_OBs[i].isBull = false;
      g_OBs[i].mitigated = false;
      g_OBs[i].active = false;

      g_OBs_HTF[i].barTime = 0;
      g_OBs_HTF[i].top = 0.0;
      g_OBs_HTF[i].bottom = 0.0;
      g_OBs_HTF[i].isBull = false;
      g_OBs_HTF[i].mitigated = false;
      g_OBs_HTF[i].active = false;
   }
   g_OBCount = 0;
   g_OBCount_HTF = 0;
}

void ResetSwingArrays()
{
   for(int i = 0; i < SWING_MAX; i++)
   {
      g_SwingHighs[i].price   = 0.0;
      g_SwingHighs[i].barTime = 0;
      g_SwingHighs[i].active  = false;
      g_SwingLows[i].price    = 0.0;
      g_SwingLows[i].barTime  = 0;
      g_SwingLows[i].active   = false;
   }
   g_SwingHighCount = 0;
   g_SwingLowCount  = 0;
   g_LastSwingDetectBar = 0;
}

//===================================================================
// INPUTS
//===================================================================
input group "══ Market Profile ══"
input bool UseMarketProfile = true;

input group "══ Signal Relax for Testing ══"
input bool RelaxSignalForTesting = false;
input bool RelaxedStochConfirm = true;
input double MinStochOversold = 28.0;
input double MaxStochOverbought = 72.0;
input double SellBiasMultiplier = 0.90;

input group "══ Parabolic SAR ══"
input double SAR_Step = 0.02;
input double SAR_Maximum = 0.20;
input bool SARRelaxForSell = true;
input double SARProximityATR = 1.1;

input group "══ Higher-Timeframe SAR Filter ══"
input bool HTF_Enable = true;
input ENUM_TIMEFRAMES HTF_Period = PERIOD_D1;

input group "══ Bollinger Bands ══"
input int    BB_Period         = 20;
input double BB_Deviation      = 2.0;
input int    BB_Shift          = 0;
input double BB_MinATRDist     = 0.9;
input double MaxBBWidthATR     = 3.6;
input double BBTolerance       = 1.05;
input double BB_ConfGateDistATR= 2.2;  // [v5.34] cap confidence if price > N×ATR from band
input double BB_ConfGateCap    = 60.0; // [v5.34] confidence cap value when gate fires (0=disable)

input group "══ ADX Filter ══"
input bool ADX_Enable = true;
input int ADX_Period = 14;
input double ADX_Level = 18.0;
input bool ADX_InvertForRange = false;

input group "══ Stochastic RSI ══"
input int RSI_Period = 14;
input int StochRSI_Period = 14;
input int StochK_Smooth = 3;
input int StochD_Smooth = 3;
input double Overbought = 80.0;
input double Oversold = 20.0;
input bool StrictCrossover = false;
input bool StochD_Confirm = false;
input bool StochBothLines = false;
input bool ShowConfidence = true;
input double Conf_MinForIcon = 60.0;
input bool UseRegimeAwareConfidence = true;
input double Conf_Min_TrendStrong = 52.0;
input double Conf_Min_TrendWeak = 72.0;
input double FVG_ConfBonus = 10.0;
input double Conf_OverrideLevel = 88.0;
input bool EnableConfluenceOverride = true; // allow high-confidence entries when some trend filters disagree
input double ConfluenceOverrideMinConf = 88.0;
input int ConfluenceOverrideMaxMissing = 2;   // count of missing filters among HTF/ADX/STOCH (0..3)
input bool AutoEnableConfluenceOverrideInTester = true;
input bool UseDistanceWeightedFVG = true;
input double FVG_FullBonusDistATR = 0.2;
input double FVG_HalfBonusDistATR = 0.5;
input bool UseADXTrendWeighting = true;
input double ADX_TrendStrong = 30.0;
input double ADX_TrendWeak = 18.0;
input double ADX_TrendStrongMult = 1.2;
input double ADX_TrendWeakMult = 0.7;
input bool UseStochExtremeBonus = true;
input double StochExtremeLow = 10.0;
input double StochExtremeHigh = 90.0;
input double StochExtremeBonus = 6.0;
input bool UseHTFAlignmentMultiplier = true;
input double HTFAlignmentMult = 1.15;

input group "══ ATR Risk ══"
input int ATR_Period = 14;
input double ATR_SL_Multi = 1.6;
input double ATR_TP_Multi = 3.0;

input group "══ Dynamic ATR Multipliers (A) ══"
input bool EnableDynamicATR = true;
input int ATR_RegimeMA_Period = 50;
input double HighVol_SL_Multi = 1.3;
input double HighVol_TP_Multi = 2.6;
input double LowVol_SL_Multi = 1.9;
input double LowVol_TP_Multi = 3.4;

input group "══ Lot Sizing ══"
input bool UseRiskPercent = true;
input double LotSize = 0.10;
input double RiskPercent = 1.0;
input bool EnableDrawdownLotScaling = true;
input double DrawdownStep1Pct = 5.0;
input double DrawdownStep1LotFactor = 0.50;
input double DrawdownStep2Pct = 8.0;
input double DrawdownStep2LotFactor = 0.25;
input bool EnableHardRiskCaps = true;
input double MaxRiskUSDPerTrade = 75.0;
input double MaxRiskPctEquityPerTrade = 1.0;
input double CommissionPerLotRoundTrip = 0.0; // broker round-trip commission per 1.0 lot
input int MagicNumber = 88321;
input int MaxPositions = 1;

input group "══ Directional Position Limits ══"
input int MaxBuyPositions = 1;
input int MaxSellPositions = 1;

input group "══ Scalping Capital Guard ══"
input double MinAccountBalance = 20.0;
input bool ForceFixedLotOnSmallAcct = true;

input group "══ Partial Close & Break-Even ══"
input bool EnablePartialClose = true;
input bool EnableBreakEven = true;
input double BE_Buffer_Points = 5.0;
input bool LowerTPAfterPartial = true;
input double PartialTP_ATRMulti = 2.0;
input bool DynamicPartialCloseByVolRegime = true;
input double PartialTP_HighVol_Multi = 2.6;
input double PartialTP_LowVol_Multi = 3.4;

input group "══ Trailing Stop ══"
input bool EnableTrailing = true;
input bool UseSARTrailing = true;
input double TrailATRMulti = 1.0;
input double SARTrail_Buffer = 0.5;

input group "══ Dynamic TP ══"
input bool UseDynamicTP = false;

input group "══ Session Filter ══"
input bool EnableSession = true;
input int SessionStartGMT = 6;
input int SessionEndGMT = 21;
input int ServerTimeOffsetGMT = 2;

input group "══ Friday EOD Close ══"
input bool CloseFridayEOD = true;
input int FridayCloseGMT = 20;

input group "══ Opposite Signal Close ══"
input bool CloseOnOpposite = true;
input bool AutoDisableCloseOnOppositeInTester = true;

input group "══ Daily Loss Limit ══"
input bool EnableDailyLimit = true;
input double MaxDailyLossPercent = 7.0;
input bool EnableDailyLossUSD = false;
input double MaxDailyLossUSD = 50.0;

input group "══ Daily Profit Cap ══"
input bool EnableDailyProfitCap = true;
input double DailyProfitCapUSD = 80.0;
input bool UsePctDailyProfitCap = false;
input double DailyProfitCapPct = 3.0;
input bool UseAccountLevelCap = false;

input group "══ Daily Trade Limit ══"
input bool EnableDailyTradeLimit = true;
input int MaxTradesPerDay = 30;
input bool EnableConsecLossBreaker = true;
input int MaxConsecLossesPerDay = 3;

input group "══ Volume Filter ══"
input bool EnableVolume = true;
input int VolMA_Period = 20;
input double VolMA_Multi = 1.0;

input group "══ Spread Filter ══"
input bool EnableSpread = true;
input double MaxSpreadPoints = 0.0;
input int Slippage = 50;

input group "══ Data Quality ══"
input int MinBarsRequired = 100;

input group "══ Signal Icons (B/S Badge) ══"
input bool ShowSignalArrows = true;
input bool ShowCloseMarkers = true;
input color BuyIconColor = clrDodgerBlue;
input color SellIconColor = clrOrangeRed;
input color BuyIconBG = C'0,60,140';
input color SellIconBG = C'140,30,0';
input color CloseWinColor = clrLimeGreen;
input color CloseLossColor = clrTomato;
input int IconFontSize = 11;
input double IconOffsetATR = 0.15;

input group "══ Fair Value Gap (FVG / iFVG) ══"
input bool ShowFVG = true;
input bool ShowiFVG = true;
input color FVGBullColor = clrMediumSeaGreen;
input color FVGBearColor = clrIndianRed;
input color iFVGBullColor = clrLimeGreen;
input color iFVGBearColor = clrFireBrick;
input int FVGExtendBars = 20;  // [v5.35] Reduced from 80 for cleaner visuals
input double FVGMinSizeATR = 0.05;
input double FVGMaxSizeATR = 8.0;
input int FVG_MaxAgeBars = 500;

input group "══ Order Blocks (OB) ══"
input bool   EnableOB = true;
input double OB_MinBodyRatio = 0.60;
input double OB_MinSizeATR = 0.30;
input double OB_ProximityATR = 0.50;
input double OB_ConfBonus = 12.0;
input double OB_FVG_ConfluenceBonus = 5.0;
input bool   ShowOB = true;
input color  OBBullColor = clrCornflowerBlue;
input color  OBBearColor = clrLightCoral;
input int    OB_MaxAgeBars = 300;
input bool   EnableHTFOB = false;
input ENUM_TIMEFRAMES HTF_OB_Period = PERIOD_H1;
input double HTF_OB_ConfBonus = 8.0;

input group "══ Multi-TF FVG Confluence (C) ══"
input bool EnableHTFFVG = true;
input ENUM_TIMEFRAMES HTF_FVG_Period = PERIOD_H1;
input double HTF_FVG_ConfBonus = 6.0;

input group "══ Swing High / Low Levels (v5.35) ══"
// Detect swing highs/lows and add confluence to confidence score.
// A swing high = bar whose high is the highest among SwingLookback bars
// on each side. A swing low = bar whose low is the lowest same way.
// When price is within SwingProximityATR×ATR of a stored level,
// SwingLevel_ConfBonus points are added (same pattern as FVG_ConfBonus).
input bool   EnableSwingLevels    = true;
input int    SwingLookback        = 5;       // bars each side to confirm swing point
input int    SwingMaxLevels       = 10;      // max stored highs / lows
input double SwingProximityATR    = 0.5;     // within N×ATR counts as "near"
input double SwingLevel_ConfBonus = 8.0;     // bonus pts when near swing level
input bool   ShowSwingLevels      = false;   // [v5.35] Default FALSE for clean backtests
input int    SwingLineExtend      = 20;      // [v5.35] Reduced from 80
input color  SwingHighColor       = clrOrangeRed;    // color for swing high lines
input color  SwingLowColor        = clrDodgerBlue;   // color for swing low lines
input int    SwingMaxAgeBars      = 150;

input group "══ Equity Curve Filter (D) ══"
input bool EnableEquityCurveFilter = true;
input int EquityCurveSMA_Period = 50;
input double EquityCurvePauseThresholdPct = 3.0;
input int EquityCurveResumeConfirmBars = 3;
input bool AutoDisableEquityCurveFilterInTester = true;

input group "══ News Filter (CSV + API) ══"
input bool UseNewsFilter = false;
input bool UseNewsCSV = true;
input string NewsCSVPath = "JB-Algo/NewsCalendar.csv";
input bool UseNewsAPI = false;
input string FMP_APIKey = "";
input int NewsRefreshHourGMT = 0;
input int AvoidTradingMinutesBeforeNews = 15;
input int AvoidTradingMinutesAfterNews = 15;

input group "══ Logging ══"
input bool ShowStats = true;
input bool ShowSignals = true;
input bool LogFVGDetails = false;
input bool ShowSessionPL = true;

input group "══ Enhancements ══"
input int WarmUpBars = 20;
input bool EnableCSVExport = true;
input bool ShowDashboard = true;
input int DashboardCorner = CORNER_LEFT_UPPER;
input color DashboardBG = C'15,25,45';
input color DashboardText = clrWhite;
input int DashboardFontSize = 9;
input bool DashboardMasterSwitch = false;
input int DashboardInstanceID = 1;
input bool TesterFastDashboard = true;
input double MaxLotHardCap = 50.0;
input bool DiagnosticsMode = false;
input bool LogStochRSIFailures = true;
input bool FailInitOnUnsafeLiveSettings = true; // block live attach when test-only/signal-killer flags are on
input bool ShowEntryMoneyRisks = true;          // on-chart label: est. $ risk / reward at last open
input bool ThrottleRiskChecks = true;           // run daily checks once per second
input int RiskChecksIntervalSec = 1;
input int HFT_PositionManageIntervalSec = 30;   // H4+ position manager throttle
input double MinRRAtEntry = 1.5;
input double MaxEstimatedRiskUSDAtEntry = 0.0; // 0=disabled
input bool EnablePositionHealthMonitor = true;
input int PositionHealthCheckMinutes = 5;
input int MaxPositionAgeHours = 24;
input datetime WFO_ForwardStartDate = 0;

input group "══ Multi-Chart & Flexibility ══"
input bool   UseCustomMagicPerSymbol = true;
input bool   IgnoreSessionForCrypto  = true;
input bool   IgnoreSpreadForCrypto   = true;
input double SpreadMultiplierCrypto  = 3.0;
input int    MaxPositionsGlobal      = 2;
input double MaxOpenRiskUSD_AllSymbols = 0.0; // 0=disabled
input double MaxOpenRiskPctEq_AllSymbols = 0.0; // 0=disabled

//===================================================================
// ACTIVE PARAMETER STRUCT
//===================================================================
struct MarketParams
{
   double atr_sl_multi, atr_tp_multi, adx_level;
   double bb_deviation, max_bb_width, bb_min_atr_dist;
   int session_start, session_end;
   double risk_percent, sar_trail_buffer;
   double daily_profit_cap, daily_loss_pct, max_risk_usd;
   ENUM_TIMEFRAMES htf_auto_period;
   int warmup_bars, fvg_max_age_bars, pos_manage_interval, swing_lookback;
   bool swing_levels_enable;
   double partial_tp_multi;
};
MarketParams g_P;

//===================================================================
// HANDLES & BUFFERS
//===================================================================
int hSAR_Entry, hSAR_HTF, hBB, hRSI, hATR, hADX;
int hATR_MA_Regime;
double sarBuf[], htfSarBuf[], bbUp[], bbMid[], bbLow[];
double rsiBuf[], atrBuf[], adxBuf[], diPlusBuf[], diMinusBuf[];
double atrMaBuf[];

//===================================================================
// SYMBOL PROPERTIES
//===================================================================
double g_VolStep, g_VolMin, g_VolMax;
int g_Digits;
long g_StopsLvl;
double g_StopsLvlPrice;
ENUM_SYMBOL_CLASS g_SymClass;
double g_SpreadLimit;
int g_ActualMagicNumber;
double g_ActualConfOverride;

//===================================================================
// POSITION TRACKING
//===================================================================
ulong g_PartialDoneTickets[];
ulong g_BreakevenDoneTickets[];
datetime g_LastTicketCleanup = 0;

//===================================================================
// DAILY STATE
//===================================================================
double g_DayStartBalance=0, g_DayStartBalanceForCap=0;
datetime g_LastDay=0;
bool g_DailyLimitHit=false, g_DailyCapHit=false;
bool g_HitDailyTradeLimit=false;   // true when g_DailyLimitHit was due to MaxTradesPerDay
int g_TodayTradeCount = 0;
datetime g_TodayTradeCountDate = 0;
double g_DayStartEquityForLossUSD = 0.0;

struct SessionStats
{
   double grossProfit;
   double grossLoss;
   int wins;
   int losses;
   datetime lastReset;
};
SessionStats g_SessionAsian;
SessionStats g_SessionLondon;
SessionStats g_SessionNY;

//===================================================================
// STATISTICS & EQUITY CURVE
//===================================================================
int g_Total=0,g_Wins=0,g_Losses=0,g_Buys=0,g_Sells=0,g_Skipped=0;
double g_GrossProfit=0,g_GrossLoss=0,g_MaxWin=0,g_MaxLoss=0;
double g_MaxConsecWin=0,g_MaxConsecLoss=0,g_LastResult=0,g_CurrConsec=0;
double g_SumReturns=0,g_SumReturnsSquared=0;
double g_RunningEquity=0,g_MaxEquity=0,g_MinEquityAfterPeak=DBL_MAX;
int g_IconCount=0;
int g_SellAttempts=0;
int g_SellBlockSAR=0, g_SellBlockHTF=0, g_SellBlockADX=0;
int g_SellBlockBB=0, g_SellBlockStoch=0, g_SellBlockVol=0;
double g_AvgConfTakenTrades = 0.0;
int g_ConfTakenCount = 0;
double g_EquityHistory[];
int g_ConsecLossesToday = 0;
bool g_ConsecLossBreakerHit = false;

struct WFOStats
{
   int total;
   int wins;
   int losses;
   double grossProfit;
   double grossLoss;
};
WFOStats g_WFO_InSample;
WFOStats g_WFO_Forward;

//===================================================================
// NEWS STATE
//===================================================================
struct NewsEvent
{
   datetime eventTime;
   string description;
   bool highImpact;
};
NewsEvent g_NewsTimes[];
datetime g_NewsLastFetch = 0;
bool g_NewsAPIActive = false;
bool g_IsNearNewsTimeCache = false;
datetime g_LastNewsCacheCheck = 0;

//===================================================================
// ENHANCEMENT STATE
//===================================================================
bool g_WarmUpComplete = false;
int g_BarsAtAttach = 0;
int g_CSVFileHandle = INVALID_HANDLE;
string g_CSVFileName = "";
bool g_IsStrategyTester = false;
int g_ActiveDashboardInstance = 0;
double g_LastTradeConfidence = 0.0;
bool g_TradingPaused = false;
bool g_TrailingStopEnabled = true;
bool g_LastTradingPausedState = false;
bool g_LastTrailingState = false;
// [v5.34] StochD_Confirm guard — counts bars since warmup to fire periodic reminder
int  g_BarsSinceWarmup = 0;
bool g_UseStochDConfirm = false;
bool g_UseStochBothLines = false;
bool g_UseConfluenceOverride = false;
bool g_UseEquityCurveFilter = true;
bool g_UseCloseOnOpposite = true;
int g_EqResumePassBars = 0;
datetime g_EqResumeLastBar = 0;
datetime g_LastRiskChecksAt = 0;
datetime g_LastPosManageAt = 0;
datetime g_LastIconBuyBar = 0;
datetime g_LastIconSellBar = 0;
datetime g_LastPosHealthCheck = 0;
int g_StochFailShortBuffer = 0;
int g_StochFailBounds = 0;
int g_StochFailDeque = 0;
int g_StochFailGeneral = 0;
ENUM_TIMEFRAMES g_HTFHandlePeriod = PERIOD_CURRENT;

//===================================================================
// DASHBOARD CONSTANTS
//===================================================================
#define DASH_PFX "JBFX_DASH_"
#define DASH_ROWS 19
string g_DashLabels[] = {
   "EA", "──────────────",
   "Symbol:", "Timeframe:", "Asset Class:",
   "Status:", "Confidence:", "FVG Zones:",
   "Daily P&L:", "Profit Cap:",
   "Positions:", "Equity:", "Spread:", "ATR:",
   "══ Session P&L ══",
   "Asian:", "London:", "New York:",
   "──────────────"
};
string g_DashValues[DASH_ROWS];
#define BTN_MANUAL_TRADE  "JBFX_BTN_MANUAL"
#define BTN_TRAILING_STOP "JBFX_BTN_TRAILING"

#define MW_PFX            "JBFX_MW_"
#define MW_HDR            "JBFX_MW_HDR"
#define MW_SYM            "JBFX_MW_SYM"
#define MW_CLK            "JBFX_MW_CLK"
#define BTN_MW_SELL       "JBFX_MW_BTN_SELL"
#define BTN_MW_BUY        "JBFX_MW_BTN_BUY"
#define MW_VOL_EDIT       "JBFX_MW_VOL"
#define BTN_MW_VOLP       "JBFX_MW_VOLP"
#define BTN_MW_VOLM       "JBFX_MW_VOLM"
#define MW_STATS          "JBFX_MW_STATS"
#define MW_LOW            "JBFX_MW_LOW"
#define MW_HIGH           "JBFX_MW_HIGH"
double g_MWVolume = 0.10;
double g_MWLotOptions[] = {0.01,0.02,0.05,0.10,0.20,0.50,1.00,2.00,5.00,10.00};
int g_MWLotIndex = 0;

//===================================================================
// GLOBALVARIABLE KEYS
//===================================================================
string GV_CapHit()     { return "JBALGO_CAPHIT_"    + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); }
string GV_CapDay()     { return "JBALGO_CAPDAY_"    + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); }
string GV_DayStartBal(){ return "JBALGO_STARTBAL_"  + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); }

double TodayAsDouble()
{
   datetime d1=iTime(_Symbol,PERIOD_D1,0);
   if(d1>0) return (double)d1;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour=0; dt.min=0; dt.sec=0;
   return (double)StructToTime(dt);
}

bool WriteCapGV(string key, double value)
{
   for(int retry = 0; retry < 3; retry++)
   {
      if(GlobalVariableSet(key, value) > 0) return true;
      Sleep(50);
   }
   Print("!!! WriteCapGV FAILED: key=", key, " err=", GetLastError());
   return false;
}

void InitSharedCap()
{
   if(!UseAccountLevelCap) return;
   double today = TodayAsDouble();
   if(!GlobalVariableCheck(GV_CapHit()))
   { WriteCapGV(GV_CapHit(), 0.0); WriteCapGV(GV_CapDay(), today); return; }
   double storedDay = GlobalVariableCheck(GV_CapDay()) ? GlobalVariableGet(GV_CapDay()) : 0.0;
   if(storedDay < today)
   { WriteCapGV(GV_CapHit(), 0.0); WriteCapGV(GV_CapDay(), today); return; }
   if(GlobalVariableGet(GV_CapHit()) > 0.0) g_DailyCapHit = true;
}

void ReleaseSharedCap()
{
   if(!UseAccountLevelCap) return;
   if(g_DailyCapHit) return;
   if(GlobalVariableCheck(GV_CapHit()) && GlobalVariableGet(GV_CapHit()) <= 0.0)
   { GlobalVariableDel(GV_CapHit()); GlobalVariableDel(GV_CapDay()); }
}

//===================================================================
// SYMBOL CLEANUP FOR EXNESS SUFFIXES
//===================================================================
string CleanSymbol(string sym)
{
   string suffixes[] = {"c","pro","ecn","m","n","p"};
   string cleaned = sym;
   for(int i = 0; i < ArraySize(suffixes); i++)
   {
      string suf = suffixes[i];
      int sufLen = StringLen(suf), symLen = StringLen(cleaned);
      if(symLen > sufLen && StringSubstr(cleaned, symLen - sufLen) == suf)
      { cleaned = StringSubstr(cleaned, 0, symLen - sufLen); break; }
   }
   return cleaned;
}

//===================================================================
// SYMBOL CLASS DETECTION
//===================================================================
ENUM_SYMBOL_CLASS DetectSymbolClass()
{
   string raw = CleanSymbol(_Symbol); StringToUpper(raw);
   string sym = raw; int rl = StringLen(raw);
   if(rl > 4) { string l = StringSubstr(raw,rl-1); if(l=="C"||l=="M"||l=="N"||l=="P") sym=StringSubstr(raw,0,rl-1); }
   string ck[] = {"BTC","ETH","LTC","XRP","BCH","ADA","SOL","DOT","BNB","DOGE","XLM","LINK","UNI","MATIC","AVAX","ATOM"};
   for(int i=0;i<ArraySize(ck);i++) if(StringFind(sym,ck[i])>=0) return SYMCLASS_CRYPTO;
   if(StringFind(sym,"XAU")>=0||StringFind(sym,"GOLD")>=0)   return SYMCLASS_METALS;
   if(StringFind(sym,"XAG")>=0||StringFind(sym,"SILVER")>=0) return SYMCLASS_METALS;
   if(StringFind(sym,"XPT")>=0||StringFind(sym,"XPD")>=0)    return SYMCLASS_METALS;
   string ek[] = {"OIL","WTI","XBR","BRENT","NGAS","GAS","USOIL","UKOIL"};
   for(int i=0;i<ArraySize(ek);i++) if(StringFind(sym,ek[i])>=0) return SYMCLASS_ENERGY;
   string ik[] = {"US30","US500","NAS","SPX","DAX","FTSE","CAC","NIKKEI","ASX","HSI","UK100","GER","JPN","VIX","SP500","USTEC","US100","USTECH"};
   for(int i=0;i<ArraySize(ik);i++) if(StringFind(sym,ik[i])>=0) return SYMCLASS_INDICES;
   string sk[] = {"AAPL","TSLA","NVDA","AMZN","MSFT","GOOGL","GOOG","META","NFLX","AMD","INTC","BABA","UBER","COIN","BRKB","JNJ","JPM","BAC","WFC","GS","MS","V","MA","PYPL","DIS","KO","PEP","MCD","NKE","WMT","TGT","HD","TSM","ASML","SAP","SONY","TM","HSBA","VOW"};
   for(int i=0;i<ArraySize(sk);i++) if(StringFind(sym,sk[i])>=0) return SYMCLASS_STOCKS;
   int cm=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_CALC_MODE);
   if(cm==5) return SYMCLASS_STOCKS;
   if(cm==2||cm==6||cm==7) return SYMCLASS_INDICES;
   string fx[] = {"EUR","GBP","AUD","NZD","USD","JPY","CHF","CAD","SGD","HKD","NOK","SEK","DKK","MXN","ZAR","TRY","PLN"};
   int m=0; for(int i=0;i<ArraySize(fx);i++) if(StringFind(sym,fx[i])>=0) m++;
   if(m>=2) return SYMCLASS_FOREX;
   if(cm==0) return SYMCLASS_FOREX;
   return SYMCLASS_UNKNOWN;
}

//===================================================================
// SYMBOL HASH FOR MAGIC NUMBER
//===================================================================
int SymbolHash(string sym)
{
   int hash = 0;
   for(int i = 0; i < StringLen(sym); i++)
      hash = (hash * 31 + StringGetCharacter(sym, i)) & 0x7FFFFFFF;
   return hash % 10000;
}

//===================================================================
// MARKET PROFILE
//===================================================================
void LoadMarketProfile()
{
   ENUM_TIMEFRAMES tf = Period();
   bool isScalp = (tf == PERIOD_M1 || tf == PERIOD_M5);
   bool isIntra = (tf == PERIOD_M15 || tf == PERIOD_H1);
   bool isSwing = (tf == PERIOD_H4 || tf == PERIOD_D1);

   if(!UseMarketProfile)
   {
      g_P.atr_sl_multi=ATR_SL_Multi; g_P.atr_tp_multi=ATR_TP_Multi; g_P.adx_level=ADX_Level;
      g_P.bb_deviation=BB_Deviation; g_P.max_bb_width=MaxBBWidthATR; g_P.bb_min_atr_dist=BB_MinATRDist;
      g_P.session_start=SessionStartGMT; g_P.session_end=SessionEndGMT;
      g_P.risk_percent=RiskPercent; g_P.sar_trail_buffer=SARTrail_Buffer;
      g_P.daily_profit_cap=DailyProfitCapUSD; g_P.daily_loss_pct=MaxDailyLossPercent;
      g_P.max_risk_usd=MaxOpenRiskUSD_AllSymbols; g_P.htf_auto_period=HTF_Period;
      g_P.warmup_bars=WarmUpBars; g_P.fvg_max_age_bars=FVG_MaxAgeBars;
      g_P.pos_manage_interval=HFT_PositionManageIntervalSec;
      g_P.swing_levels_enable=EnableSwingLevels; g_P.swing_lookback=SwingLookback;
      g_P.partial_tp_multi=PartialTP_ATRMulti;
      Print("Profile: MANUAL"); return;
   }

   // Timeframe defaults first (2nd dimension).
   if(isScalp)
   {
      g_P.warmup_bars = 80;
      g_P.fvg_max_age_bars = (tf==PERIOD_M1)?60:120;
      g_P.pos_manage_interval = (tf==PERIOD_M1)?1:3;
      g_P.swing_levels_enable = false;
      g_P.swing_lookback = 20;
      g_P.partial_tp_multi = 1.5;
      g_P.htf_auto_period = PERIOD_H1;
   }
   else if(isIntra)
   {
      g_P.warmup_bars = 30;
      g_P.fvg_max_age_bars = 200;
      g_P.pos_manage_interval = 10;
      g_P.swing_levels_enable = true;
      g_P.swing_lookback = 7;
      g_P.partial_tp_multi = 2.0;
      g_P.htf_auto_period = PERIOD_H4;
   }
   else
   {
      g_P.warmup_bars = 20;
      g_P.fvg_max_age_bars = 500;
      g_P.pos_manage_interval = 30;
      g_P.swing_levels_enable = true;
      g_P.swing_lookback = 5;
      g_P.partial_tp_multi = 2.5;
      g_P.htf_auto_period = PERIOD_D1;
   }

   switch(g_SymClass)
   {
      case SYMCLASS_FOREX:
         g_P.atr_sl_multi=isScalp?1.8:1.6;g_P.atr_tp_multi=isScalp?2.5:3.0;g_P.adx_level=20.0;
         g_P.bb_deviation=2.0;g_P.max_bb_width=2.5;g_P.bb_min_atr_dist=0.5;
         g_P.session_start=8;g_P.session_end=17;
         g_P.risk_percent=1.0;g_P.sar_trail_buffer=0.4;g_P.daily_profit_cap=80.0;
         g_P.daily_loss_pct=3.0; g_P.max_risk_usd=75.0; break;
      case SYMCLASS_METALS:
         g_P.atr_sl_multi=isScalp?2.0:1.8;g_P.atr_tp_multi=isScalp?3.0:3.5;g_P.adx_level=22.0;
         g_P.bb_deviation=2.0;g_P.max_bb_width=2.5;g_P.bb_min_atr_dist=0.5;
         g_P.session_start=8;g_P.session_end=17;
         g_P.risk_percent=0.5;g_P.sar_trail_buffer=0.5;g_P.daily_loss_pct=5.0;
         g_P.daily_profit_cap=150.0;g_P.max_risk_usd=100.0; break;
      case SYMCLASS_CRYPTO:
         g_P.atr_sl_multi=isScalp?2.5:2.0;g_P.atr_tp_multi=isScalp?3.5:4.0;g_P.adx_level=18.0;
         g_P.bb_deviation=2.3;g_P.max_bb_width=4.0;g_P.bb_min_atr_dist=0.7;
         g_P.session_start=0;g_P.session_end=24;
         g_P.risk_percent=0.25;g_P.sar_trail_buffer=0.8;g_P.daily_loss_pct=8.0;
         g_P.daily_profit_cap=200.0;g_P.max_risk_usd=150.0;
         if(isSwing) g_P.htf_auto_period=PERIOD_W1; break;
      case SYMCLASS_INDICES:
         g_P.atr_sl_multi=isScalp?1.8:1.7;g_P.atr_tp_multi=isScalp?2.8:3.2;g_P.adx_level=22.0;
         g_P.bb_deviation=2.0;g_P.max_bb_width=2.5;g_P.bb_min_atr_dist=0.5;
         g_P.session_start=9;g_P.session_end=22;
         g_P.risk_percent=0.5;g_P.sar_trail_buffer=0.5;g_P.daily_loss_pct=5.0;
         g_P.daily_profit_cap=150.0;g_P.max_risk_usd=100.0; break;
      case SYMCLASS_ENERGY:
         g_P.atr_sl_multi=2.0;g_P.atr_tp_multi=3.0;g_P.adx_level=20.0;
         g_P.bb_deviation=2.0;g_P.max_bb_width=2.5;g_P.bb_min_atr_dist=0.5;
         g_P.session_start=8;g_P.session_end=17;
         g_P.risk_percent=0.5;g_P.sar_trail_buffer=0.5;g_P.daily_profit_cap=40.0;
         g_P.daily_loss_pct=5.0; g_P.max_risk_usd=MaxOpenRiskUSD_AllSymbols; break;
      case SYMCLASS_STOCKS:
         g_P.atr_sl_multi=1.5;g_P.atr_tp_multi=2.5;g_P.adx_level=20.0;
         g_P.bb_deviation=2.0;g_P.max_bb_width=2.5;g_P.bb_min_atr_dist=0.5;
         g_P.session_start=14;g_P.session_end=21;
         g_P.risk_percent=0.3;g_P.sar_trail_buffer=0.4;g_P.daily_profit_cap=20.0;
         g_P.daily_loss_pct=4.0; g_P.max_risk_usd=MaxOpenRiskUSD_AllSymbols; break;
      default:
         g_P.atr_sl_multi=isScalp?1.8:1.6;g_P.atr_tp_multi=isScalp?2.5:3.0;g_P.adx_level=22.0;
         g_P.bb_deviation=2.0;g_P.max_bb_width=2.5;g_P.bb_min_atr_dist=0.5;
         g_P.session_start=8;g_P.session_end=17;
         g_P.risk_percent=0.5;g_P.sar_trail_buffer=0.5;g_P.daily_profit_cap=80.0;
         g_P.daily_loss_pct=3.0; g_P.max_risk_usd=75.0; break;
   }
   Print("Profile:AUTO[",SYMCLASS_NAMES[(int)g_SymClass],"] Cap:$",g_P.daily_profit_cap);
}

//===================================================================
// SPREAD LIMIT
//===================================================================
double ResolveSpreadLimit()
{
   double al;
   switch(g_SymClass)
   {
      case SYMCLASS_FOREX:   al=30.0;   break;
      case SYMCLASS_METALS:  al=200.0;  break;
      case SYMCLASS_CRYPTO:  al=8000.0; break;
      case SYMCLASS_INDICES: al=500.0;  break;
      case SYMCLASS_ENERGY:  al=300.0;  break;
      case SYMCLASS_STOCKS:  al=5.0;    break;
      default:               al=100.0;  break;
   }
   if(g_SymClass==SYMCLASS_CRYPTO && IgnoreSpreadForCrypto) return al*SpreadMultiplierCrypto;
   if(MaxSpreadPoints<=0.0) return al;
   if(MaxSpreadPoints<al*0.3) return al;
   return MaxSpreadPoints;
}

double ResolveDailyProfitCap()
{
   if(UsePctDailyProfitCap && g_DayStartBalanceForCap > 0.0)
      return g_DayStartBalanceForCap * DailyProfitCapPct / 100.0;
   return g_P.daily_profit_cap;
}

double ResolveDailyLossPercent()
{
   if(UseMarketProfile && g_P.daily_loss_pct > 0.0) return g_P.daily_loss_pct;
   return MaxDailyLossPercent;
}

double ResolveGlobalRiskCapUSD()
{
   if(UseMarketProfile && g_P.max_risk_usd > 0.0) return g_P.max_risk_usd;
   return MaxOpenRiskUSD_AllSymbols;
}

ENUM_TIMEFRAMES ResolveHTFPeriod()
{
   if(UseMarketProfile && g_P.htf_auto_period > 0) return g_P.htf_auto_period;
   return HTF_Period;
}

int ResolveWarmUpBars()
{
   if(UseMarketProfile && g_P.warmup_bars > 0) return g_P.warmup_bars;
   return WarmUpBars;
}

int ResolveFVGMaxAgeBars()
{
   if(UseMarketProfile && g_P.fvg_max_age_bars > 0) return g_P.fvg_max_age_bars;
   return FVG_MaxAgeBars;
}

int ResolvePosManageIntervalSec()
{
   if(UseMarketProfile && g_P.pos_manage_interval > 0) return g_P.pos_manage_interval;
   return HFT_PositionManageIntervalSec;
}

bool ResolveSwingLevelsEnabled()
{
   if(!EnableSwingLevels) return false;
   if(UseMarketProfile) return g_P.swing_levels_enable;
   return true;
}

int ResolveSwingLookback()
{
   if(UseMarketProfile && g_P.swing_lookback > 0) return g_P.swing_lookback;
   return SwingLookback;
}

double ResolvePartialTPMulti()
{
   if(UseMarketProfile && g_P.partial_tp_multi > 0.0) return g_P.partial_tp_multi;
   return PartialTP_ATRMulti;
}

double ResolveConfThreshold(double adx)
{
   if(!UseRegimeAwareConfidence) return Conf_MinForIcon;
   if(adx >= ADX_TrendStrong) return Conf_Min_TrendStrong;
   if(adx < ADX_TrendWeak) return Conf_Min_TrendWeak;
   return Conf_MinForIcon;
}

void UpdateWFOStats(double profit)
{
   if(WFO_ForwardStartDate<=0) return;
   datetime nowT=TimeCurrent();
   bool isForward=(nowT>=WFO_ForwardStartDate);
   WFOStats &st=isForward?g_WFO_Forward:g_WFO_InSample;
   st.total++;
   if(profit>=0){ st.wins++; st.grossProfit+=profit; }
   else{ st.losses++; st.grossLoss+=MathAbs(profit); }
}

void InvalidateBrokenSwingLevels(double closeNow)
{
   for(int i=0;i<SWING_MAX;i++)
   {
      if(g_SwingHighs[i].active && closeNow>g_SwingHighs[i].price) g_SwingHighs[i].active=false;
      if(g_SwingLows[i].active && closeNow<g_SwingLows[i].price) g_SwingLows[i].active=false;
      if(SwingMaxAgeBars>0)
      {
         datetime tNow=iTime(_Symbol,PERIOD_CURRENT,0);
         int maxAgeSec=PeriodSeconds(PERIOD_CURRENT)*SwingMaxAgeBars;
         if(g_SwingHighs[i].active && (tNow-g_SwingHighs[i].barTime)>maxAgeSec) g_SwingHighs[i].active=false;
         if(g_SwingLows[i].active && (tNow-g_SwingLows[i].barTime)>maxAgeSec) g_SwingLows[i].active=false;
      }
   }
}

void EnsureHTFSarHandleFresh()
{
   ENUM_TIMEFRAMES need=ResolveHTFPeriod();
   if(hSAR_HTF!=INVALID_HANDLE && g_HTFHandlePeriod==need) return;
   if(hSAR_HTF!=INVALID_HANDLE) IndicatorRelease(hSAR_HTF);
   hSAR_HTF=iSAR(_Symbol,need,SAR_Step,SAR_Maximum);
   g_HTFHandlePeriod=need;
}

//===================================================================
// INPUT VALIDATION
//===================================================================
bool ValidateInputs()
{
   bool valid = true;
   if(MaxBuyPositions  > MaxPositions) { Alert("MaxBuyPositions > MaxPositions");  valid=false; }
   if(MaxSellPositions > MaxPositions) { Alert("MaxSellPositions > MaxPositions"); valid=false; }
   if(UseRiskPercent && RiskPercent<=0){ Alert("RiskPercent must be > 0");         valid=false; }
   if(!UseRiskPercent && (LotSize<g_VolMin||LotSize>g_VolMax)){ Alert("LotSize out of range"); valid=false; }
   if(Oversold>=Overbought)            { Alert("Oversold >= Overbought");           valid=false; }
   return valid;
}

bool EnsureFolderExists(string path)
{
   if(FolderCreate(path)) return true;
   int err = GetLastError();
   return (err==5000||err==0);
}

//===================================================================
// FVG SLOT MANAGEMENT — [ERR-1 FIXED]
// MQL5 does not allow ternary-based array references.
// Solution: pass the array explicitly by reference.
//===================================================================
int FindFVGSlotInArray(FVGData &arr[], int arrSize)
{
   for(int i = 0; i < arrSize; i++)
      if(!arr[i].active) return i;

   int oldest = 0;
   for(int i = 1; i < arrSize; i++)
      if(arr[i].midTime > 0 && arr[i].midTime < arr[oldest].midTime)
         oldest = i;
   return oldest;
}

int FindOBSlotInArray(OBData &arr[], int arrSize)
{
   for(int i = 0; i < arrSize; i++)
      if(!arr[i].active) return i;

   int oldest = 0;
   for(int i = 1; i < arrSize; i++)
      if(arr[i].barTime > 0 && arr[i].barTime < arr[oldest].barTime)
         oldest = i;
   return oldest;
}

//===================================================================
// FVG DETECTION — [ERR-2 FIXED]
// Replaced ternary array reference with explicit if/else blocks
// for the HTF and entry-TF paths.
//===================================================================
void DetectNewFVG(double atr, bool isHTF = false)
{
   if(!ShowFVG && !ShowiFVG && !isHTF) return;

   ENUM_TIMEFRAMES tf = isHTF ? HTF_FVG_Period : PERIOD_CURRENT;
   int tfSec=PeriodSeconds(tf);
   datetime t0=iTime(_Symbol,tf,0), t1=iTime(_Symbol,tf,1), t2=iTime(_Symbol,tf,2);
   if(tfSec<=0 || t0<=0 || t1<=0 || t2<=0) return;
   if((t0-t1)<tfSec) return; // bar-1 closure safety
   if(t2==t0) return;        // never tag current opening bar as FVG midTime

   double high3  = iHigh(_Symbol, tf, 3);
   double low3   = iLow (_Symbol, tf, 3);
   double high1  = iHigh(_Symbol, tf, 1);
   double low1   = iLow (_Symbol, tf, 1);
   datetime midT = t2;

   double minSz = (FVGMinSizeATR>0 && atr>0) ? FVGMinSizeATR*atr : 0;
   double maxSz = (FVGMaxSizeATR>0 && atr>0) ? FVGMaxSizeATR*atr : DBL_MAX;
   if(atr>0 && MathAbs(high3-low1) < 0.1*atr) return;

   // ── Bullish FVG ──────────────────────────────────────────────
   if(high3 < low1)
   {
      double gap = low1 - high3;
      if(gap >= minSz && gap <= maxSz)
      {
         if(isHTF)
         {
            bool dup = false;
            for(int i=0;i<FVG_MAX;i++)
               if(g_FVGs_HTF[i].active && g_FVGs_HTF[i].midTime==midT && g_FVGs_HTF[i].isBull){ dup=true; break; }
            if(!dup)
            {
               int slot = FindFVGSlotInArray(g_FVGs_HTF, FVG_MAX);
               if(g_FVGs_HTF[slot].active) ObjectDelete(0, OBJ_PFX+"HTF_FVG_"+IntegerToString(slot));
               g_FVGs_HTF[slot].midTime=midT; g_FVGs_HTF[slot].top=low1; g_FVGs_HTF[slot].bottom=high3;
               g_FVGs_HTF[slot].retestPrice=0; g_FVGs_HTF[slot].isBull=true;
               g_FVGs_HTF[slot].mitigated=false; g_FVGs_HTF[slot].active=true;
               g_FVGCount_HTF++;
               if(LogFVGDetails) Print("FVG[NEW][HTF Bull] Gap:",DoubleToString(gap/_Point,1),"pts @",TimeToString(midT));
            }
         }
         else
         {
            bool dup = false;
            for(int i=0;i<FVG_MAX;i++)
               if(g_FVGs[i].active && g_FVGs[i].midTime==midT && g_FVGs[i].isBull){ dup=true; break; }
            if(!dup)
            {
               int slot = FindFVGSlotInArray(g_FVGs, FVG_MAX);
               if(g_FVGs[slot].active) ObjectDelete(0, OBJ_PFX+"FVG_"+IntegerToString(slot));
               g_FVGs[slot].midTime=midT; g_FVGs[slot].top=low1; g_FVGs[slot].bottom=high3;
               g_FVGs[slot].retestPrice=0; g_FVGs[slot].isBull=true;
               g_FVGs[slot].mitigated=false; g_FVGs[slot].active=true;
               g_FVGCount++;
               DrawFVGRect(slot, atr);
               if(LogFVGDetails) Print("FVG[NEW][Bull] Gap:",DoubleToString(gap/_Point,1),"pts @",TimeToString(midT));
            }
         }
      }
   }

   // ── Bearish FVG ──────────────────────────────────────────────
   if(low3 > high1)
   {
      double gap = low3 - high1;
      if(gap >= minSz && gap <= maxSz)
      {
         if(isHTF)
         {
            bool dup = false;
            for(int i=0;i<FVG_MAX;i++)
               if(g_FVGs_HTF[i].active && g_FVGs_HTF[i].midTime==midT && !g_FVGs_HTF[i].isBull){ dup=true; break; }
            if(!dup)
            {
               int slot = FindFVGSlotInArray(g_FVGs_HTF, FVG_MAX);
               if(g_FVGs_HTF[slot].active) ObjectDelete(0, OBJ_PFX+"HTF_FVG_"+IntegerToString(slot));
               g_FVGs_HTF[slot].midTime=midT; g_FVGs_HTF[slot].top=low3; g_FVGs_HTF[slot].bottom=high1;
               g_FVGs_HTF[slot].retestPrice=0; g_FVGs_HTF[slot].isBull=false;
               g_FVGs_HTF[slot].mitigated=false; g_FVGs_HTF[slot].active=true;
               g_FVGCount_HTF++;
               if(LogFVGDetails) Print("FVG[NEW][HTF Bear] Gap:",DoubleToString(gap/_Point,1),"pts @",TimeToString(midT));
            }
         }
         else
         {
            bool dup = false;
            for(int i=0;i<FVG_MAX;i++)
               if(g_FVGs[i].active && g_FVGs[i].midTime==midT && !g_FVGs[i].isBull){ dup=true; break; }
            if(!dup)
            {
               int slot = FindFVGSlotInArray(g_FVGs, FVG_MAX);
               if(g_FVGs[slot].active) ObjectDelete(0, OBJ_PFX+"FVG_"+IntegerToString(slot));
               g_FVGs[slot].midTime=midT; g_FVGs[slot].top=low3; g_FVGs[slot].bottom=high1;
               g_FVGs[slot].retestPrice=0; g_FVGs[slot].isBull=false;
               g_FVGs[slot].mitigated=false; g_FVGs[slot].active=true;
               g_FVGCount++;
               DrawFVGRect(slot, atr);
               if(LogFVGDetails) Print("FVG[NEW][Bear] Gap:",DoubleToString(gap/_Point,1),"pts @",TimeToString(midT));
            }
         }
      }
   }
}

void CleanupOldFVGs()
{
   int fvgMaxAgeBars = ResolveFVGMaxAgeBars();
   if(fvgMaxAgeBars <= 0) return;
   datetime curTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   int maxAgeSec = PeriodSeconds(PERIOD_CURRENT) * fvgMaxAgeBars;
   for(int i = 0; i < FVG_MAX; i++)
   {
      if(g_FVGs[i].active && g_FVGs[i].midTime > 0 && curTime - g_FVGs[i].midTime > maxAgeSec)
      {
         if(LogFVGDetails)
            Print("FVG[EXPIRED] Slot:",i," Age:",IntegerToString((curTime-g_FVGs[i].midTime)/PeriodSeconds(PERIOD_CURRENT)),"bars");
         g_FVGs[i].active = false;
         string nm = OBJ_PFX+"FVG_"+IntegerToString(i);
         if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm);
      }
   }
}

void DrawFVGRect(int slot, double atr = 0.0)
{
   if(!g_FVGs[slot].active) return;
   
   // Keep FVG/iFVG visuals available in visual backtests.
   // (They are useful for validation and debugging signal context.)
   // ───────────────────────────────────────────────────────────────
   
   bool mitd=g_FVGs[slot].mitigated, bull=g_FVGs[slot].isBull;
   double top=g_FVGs[slot].top, bot=g_FVGs[slot].bottom;
   string name = OBJ_PFX+"FVG_"+IntegerToString(slot);
   double usedATR = (atr>0.0) ? atr : (g_LastATR>0.0 ? g_LastATR : 100.0*_Point);
   double remnant = MathMax(50.0*_Point, 0.3*usedATR);
   if(mitd && g_FVGs[slot].retestPrice > 0.0)
   {
      if(!ShowiFVG){ ObjectDelete(0,name); return; }
      double rp = g_FVGs[slot].retestPrice;
      if(bull){ double nt=rp,nb=bot; if(nt<=nb+remnant){ ObjectDelete(0,name); return; } top=nt; bot=nb; }
      else    { double nt=top,nb=rp; if(nb>=nt-remnant){ ObjectDelete(0,name); return; } top=nt; bot=nb; }
   }
   else if(mitd && !ShowiFVG){ ObjectDelete(0,name); return; }
   else if(!mitd && !ShowFVG){ ObjectDelete(0,name); return; }
   color clr = mitd?(bull?iFVGBullColor:iFVGBearColor):(bull?FVGBullColor:FVGBearColor);
   datetime t1 = g_FVGs[slot].midTime;
   datetime t2 = iTime(_Symbol,PERIOD_CURRENT,0)+(datetime)(PeriodSeconds(PERIOD_CURRENT)*FVGExtendBars);
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
   ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,top,t2,bot);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   string tag = mitd?(bull?"iFVG Bull(cut)":"iFVG Bear(cut)"):(bull?"FVG Bull":"FVG Bear");
   ObjectSetString(0,name,OBJPROP_TOOLTIP,tag+" T:"+DoubleToString(top,g_Digits)+" B:"+DoubleToString(bot,g_Digits));
   ChartRedraw(0);
}

void UpdateFVGMitigation(double bid, double ask)
{
   if(!ShowFVG && !ShowiFVG) return;
   for(int i = 0; i < FVG_MAX; i++)
   {
      if(!g_FVGs[i].active || g_FVGs[i].mitigated) continue;
      if(bid <= g_FVGs[i].top && ask >= g_FVGs[i].bottom)
      {
         g_FVGs[i].retestPrice = g_FVGs[i].isBull ? MathMin(bid,g_FVGs[i].top) : MathMax(ask,g_FVGs[i].bottom);
         g_FVGs[i].mitigated = true;
         DrawFVGRect(i, g_LastATR);
         if(LogFVGDetails)
            Print("FVG[MITIGATED][",g_FVGs[i].isBull?"Bull":"Bear","] Slot:",i," @",DoubleToString(g_FVGs[i].retestPrice,g_Digits));
         else if(ShowSignals)
            Print("FVG->iFVG(CUT)[",g_FVGs[i].isBull?"Bull":"Bear","]@",DoubleToString(g_FVGs[i].retestPrice,g_Digits));
      }
   }
}

void RefreshFVGBoxes()
{
   CleanupOldFVGs();
   int drawn = 0;
   for(int i=FVG_MAX-1; i>=0 && drawn<FVG_DISPLAY_MAX; i--)
      if(g_FVGs[i].active){ DrawFVGRect(i,g_LastATR); drawn++; }
   for(int i=0; i<FVG_MAX; i++)
   {
      if(!g_FVGs[i].active) continue;
      int newer = 0;
      for(int j=i+1; j<FVG_MAX; j++) if(g_FVGs[j].active) newer++;
      if(newer >= FVG_DISPLAY_MAX)
      { string nm=OBJ_PFX+"FVG_"+IntegerToString(i); if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm); }
   }
}

void DetectNewOB(double atr, bool isHTF = false)
{
   if(!EnableOB) return;
   if(!ShowOB && !isHTF) return;

   ENUM_TIMEFRAMES tf = isHTF ? HTF_OB_Period : PERIOD_CURRENT;
   int tfSec=PeriodSeconds(tf);
   datetime t0=iTime(_Symbol,tf,0), t1t=iTime(_Symbol,tf,1), t2t=iTime(_Symbol,tf,2);
   if(tfSec<=0 || t0<=0 || t1t<=0 || t2t<=0) return;
   if((t0-t1t)<tfSec) return;

   double o3=iOpen(_Symbol,tf,3), h3=iHigh(_Symbol,tf,3), l3=iLow(_Symbol,tf,3), c3=iClose(_Symbol,tf,3);
   double o2=iOpen(_Symbol,tf,2), h2=iHigh(_Symbol,tf,2), l2=iLow(_Symbol,tf,2), c2=iClose(_Symbol,tf,2);
   double o1=iOpen(_Symbol,tf,1), h1=iHigh(_Symbol,tf,1), l1=iLow(_Symbol,tf,1), c1=iClose(_Symbol,tf,1);
   datetime obTime=t2t;
   double atrRef=(atr>0.0)?atr:g_LastATR;
   double minSize=(OB_MinSizeATR>0.0&&atrRef>0.0)?(OB_MinSizeATR*atrRef):0.0;
   if((h2-l2)<minSize) return;

   double impulseRange=MathMax(h1-l1,_Point);
   double bodyRatio=MathAbs(c1-o1)/impulseRange;
   if(bodyRatio<OB_MinBodyRatio) return;
   double obRange=MathMax(h2-l2,_Point);
   double obBodyRatio=MathAbs(c2-o2)/obRange;
   if(obBodyRatio<0.45) return;

   bool bullOB=(c2<o2)&&(c1>h2)&&((l1-h3)>0.0);
   bool bearOB=(c2>o2)&&(c1<l2)&&((l3-h1)>0.0);
   if(bullOB && ((c1-h2)<minSize)) bullOB=false;
   if(bearOB && ((l2-c1)<minSize)) bearOB=false;
   if(!bullOB && !bearOB) return;

   if(isHTF)
   {
      bool dup=false;
      for(int i=0;i<OB_MAX;i++)
         if(g_OBs_HTF[i].active && g_OBs_HTF[i].barTime==obTime && g_OBs_HTF[i].isBull==bullOB){ dup=true; break; }
      if(!dup)
      {
         int slot=FindOBSlotInArray(g_OBs_HTF,OB_MAX);
         g_OBs_HTF[slot].barTime=obTime;
         g_OBs_HTF[slot].top=h2;
         g_OBs_HTF[slot].bottom=l2;
         g_OBs_HTF[slot].isBull=bullOB;
         g_OBs_HTF[slot].mitigated=false;
         g_OBs_HTF[slot].active=true;
         g_OBCount_HTF++;
      }
      return;
   }

   bool dup=false;
   for(int i=0;i<OB_MAX;i++)
      if(g_OBs[i].active && g_OBs[i].barTime==obTime && g_OBs[i].isBull==bullOB){ dup=true; break; }
   if(dup) return;

   int slot=FindOBSlotInArray(g_OBs,OB_MAX);
   if(g_OBs[slot].active)
   {
      string oldName=OBJ_PFX+"OB_"+IntegerToString(slot);
      if(ObjectFind(0,oldName)>=0) ObjectDelete(0,oldName);
   }
   g_OBs[slot].barTime=obTime;
   g_OBs[slot].top=h2;
   g_OBs[slot].bottom=l2;
   g_OBs[slot].isBull=bullOB;
   g_OBs[slot].mitigated=false;
   g_OBs[slot].active=true;
   g_OBCount++;
}

void DrawOBRect(int slot)
{
   if(!EnableOB || !ShowOB) return;
   if(!g_OBs[slot].active) return;
   string name=OBJ_PFX+"OB_"+IntegerToString(slot);
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
   datetime t1=g_OBs[slot].barTime;
   datetime t2=t1 + (datetime)(PeriodSeconds(PERIOD_CURRENT)*MathMax(1,OB_MaxAgeBars));
   ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,g_OBs[slot].top,t2,g_OBs[slot].bottom);
   ObjectSetInteger(0,name,OBJPROP_COLOR,g_OBs[slot].isBull?OBBullColor:OBBearColor);
   ObjectSetInteger(0,name,OBJPROP_FILL,true);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,name,OBJPROP_BACK,true);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,(g_OBs[slot].isBull?"OB Bull":"OB Bear")+
                    " T:"+DoubleToString(g_OBs[slot].top,g_Digits)+
                    " B:"+DoubleToString(g_OBs[slot].bottom,g_Digits));
}

void CleanupOldOBs()
{
   if(OB_MaxAgeBars<=0) return;
   datetime curTime=iTime(_Symbol,PERIOD_CURRENT,0);
   int maxAgeSec=PeriodSeconds(PERIOD_CURRENT)*OB_MaxAgeBars;
   for(int i=0;i<OB_MAX;i++)
   {
      if(!g_OBs[i].active || g_OBs[i].barTime<=0) continue;
      if(curTime-g_OBs[i].barTime<=maxAgeSec) continue;
      g_OBs[i].active=false;
      string nm=OBJ_PFX+"OB_"+IntegerToString(i);
      if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm);
   }
}

void UpdateOBMitigation(double bid, double ask)
{
   if(!EnableOB) return;
   for(int i=0;i<OB_MAX;i++)
   {
      if(!g_OBs[i].active || g_OBs[i].mitigated) continue;
      if(bid<=g_OBs[i].top && ask>=g_OBs[i].bottom)
      {
         g_OBs[i].mitigated=true;
         g_OBs[i].active=false;
         string nm=OBJ_PFX+"OB_"+IntegerToString(i);
         if(ObjectFind(0,nm)>=0) ObjectDelete(0,nm);
      }
   }
}

void RefreshOBBoxes()
{
   CleanupOldOBs();
   for(int i=0;i<OB_MAX;i++)
      if(g_OBs[i].active) DrawOBRect(i);
}

//===================================================================
// SWING HIGH / LOW DETECTION  [v5.35]
//===================================================================

// Draw a dashed horizontal line for a swing level on the chart.
void DrawSwingLine(bool isHigh, double price, datetime barTime, int slot)
{
   // ── [v5.35 FIX-D] Don't draw in Strategy Tester ────────────────
   if(MQLInfoInteger(MQL_TESTER)) return;
   // ───────────────────────────────────────────────────────────────
   
   if(!ShowSwingLevels) return;
   string name = OBJ_PFX + (isHigh ? "SWH_" : "SWL_") + IntegerToString(slot);
   if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
   datetime t2 = barTime + (datetime)(PeriodSeconds(PERIOD_CURRENT) * SwingLineExtend);
   ObjectCreate(0, name, OBJ_TREND, 0, barTime, price, t2, price);
   color lineClr = isHigh ? SwingHighColor : SwingLowColor;
   ObjectSetInteger(0, name, OBJPROP_COLOR,     lineClr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,     STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,     1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   ObjectSetString(0,  name, OBJPROP_TOOLTIP,
      (isHigh ? "Swing High @ " : "Swing Low @ ") + DoubleToString(price, g_Digits));
}

// Remove all swing level chart objects.
void CleanupSwingObjects()
{
   for(int i = 0; i < SWING_MAX; i++)
   {
      string nh = OBJ_PFX + "SWH_" + IntegerToString(i);
      string nl = OBJ_PFX + "SWL_" + IntegerToString(i);
      if(ObjectFind(0, nh) >= 0) ObjectDelete(0, nh);
      if(ObjectFind(0, nl) >= 0) ObjectDelete(0, nl);
   }
}

// Scan for new swing highs and lows on the current bar.
// Uses SwingLookback bars on each side to confirm a pivot.
// Only scans the pivot bar at index = SwingLookback+1 (fully confirmed).
// Stores up to SwingMaxLevels levels in circular fashion.
void DetectSwingLevels()
{
   int swingLookback = ResolveSwingLookback();
   if(!ResolveSwingLevelsEnabled() || swingLookback < 1) return;
   int pivotBar = swingLookback + 1;  // the bar old enough to have N bars each side
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);
   if(totalBars < pivotBar + swingLookback + 2) return;

   datetime pivotTime = iTime(_Symbol, PERIOD_CURRENT, pivotBar);
   if(pivotTime == g_LastSwingDetectBar) return;  // already scanned this bar
   g_LastSwingDetectBar = pivotTime;

   double pivotHigh = iHigh(_Symbol, PERIOD_CURRENT, pivotBar);
   double pivotLow  = iLow (_Symbol, PERIOD_CURRENT, pivotBar);

   // ── Check swing HIGH ─────────────────────────────────────────
   bool isSwingHigh = true;
   for(int j = 1; j <= swingLookback && isSwingHigh; j++)
   {
      if(iHigh(_Symbol, PERIOD_CURRENT, pivotBar - j) >= pivotHigh) isSwingHigh = false;
      if(iHigh(_Symbol, PERIOD_CURRENT, pivotBar + j) >= pivotHigh) isSwingHigh = false;
   }
   if(isSwingHigh)
   {
      // Avoid storing duplicate levels (within 0.1 ATR of existing)
      double minDist = (g_LastATR > 0) ? 0.1 * g_LastATR : _Point * 10;
      bool isDup = false;
      for(int i = 0; i < SWING_MAX; i++)
         if(g_SwingHighs[i].active && MathAbs(g_SwingHighs[i].price - pivotHigh) < minDist)
         { isDup = true; break; }

      if(!isDup)
      {
         int slot = g_SwingHighCount % SwingMaxLevels;
         g_SwingHighs[slot].price   = pivotHigh;
         g_SwingHighs[slot].barTime = pivotTime;
         g_SwingHighs[slot].active  = true;
         g_SwingHighCount++;
         DrawSwingLine(true, pivotHigh, pivotTime, slot);
         if(ShowSignals) Print("SwingHigh @ ", DoubleToString(pivotHigh, g_Digits),
                               " t=", TimeToString(pivotTime));
      }
   }

   // ── Check swing LOW ──────────────────────────────────────────
   bool isSwingLow = true;
   for(int j = 1; j <= swingLookback && isSwingLow; j++)
   {
      if(iLow(_Symbol, PERIOD_CURRENT, pivotBar - j) <= pivotLow) isSwingLow = false;
      if(iLow(_Symbol, PERIOD_CURRENT, pivotBar + j) <= pivotLow) isSwingLow = false;
   }
   if(isSwingLow)
   {
      double minDist = (g_LastATR > 0) ? 0.1 * g_LastATR : _Point * 10;
      bool isDup = false;
      for(int i = 0; i < SWING_MAX; i++)
         if(g_SwingLows[i].active && MathAbs(g_SwingLows[i].price - pivotLow) < minDist)
         { isDup = true; break; }

      if(!isDup)
      {
         int slot = g_SwingLowCount % SwingMaxLevels;
         g_SwingLows[slot].price   = pivotLow;
         g_SwingLows[slot].barTime = pivotTime;
         g_SwingLows[slot].active  = true;
         g_SwingLowCount++;
         DrawSwingLine(false, pivotLow, pivotTime, slot);
         if(ShowSignals) Print("SwingLow  @ ", DoubleToString(pivotLow, g_Digits),
                               " t=", TimeToString(pivotTime));
      }
   }
}

// Refresh all stored swing level lines (called on chart events / new bars).
void RefreshSwingLines()
{
   if(!ShowSwingLevels) return;
   for(int i = 0; i < SWING_MAX; i++)
   {
      if(g_SwingHighs[i].active)
         DrawSwingLine(true,  g_SwingHighs[i].price, g_SwingHighs[i].barTime, i);
      if(g_SwingLows[i].active)
         DrawSwingLine(false, g_SwingLows[i].price,  g_SwingLows[i].barTime,  i);
   }
}

// Returns true if close is within SwingProximityATR×ATR of any stored swing HIGH.
// Used for SELL confluence (price approaching resistance).
bool IsNearSwingHigh(double close, double atr)
{
   if(!ResolveSwingLevelsEnabled() || SwingLevel_ConfBonus <= 0.0 || atr <= 0.0) return false;
   double proximity = SwingProximityATR * atr;
   for(int i = 0; i < SWING_MAX; i++)
   {
      if(!g_SwingHighs[i].active) continue;
      if(MathAbs(close - g_SwingHighs[i].price) <= proximity) return true;
   }
   return false;
}

// Returns true if close is within SwingProximityATR×ATR of any stored swing LOW.
// Used for BUY confluence (price approaching support).
bool IsNearSwingLow(double close, double atr)
{
   if(!ResolveSwingLevelsEnabled() || SwingLevel_ConfBonus <= 0.0 || atr <= 0.0) return false;
   double proximity = SwingProximityATR * atr;
   for(int i = 0; i < SWING_MAX; i++)
   {
      if(!g_SwingLows[i].active) continue;
      if(MathAbs(close - g_SwingLows[i].price) <= proximity) return true;
   }
   return false;
}

bool IsNearActiveFVG(bool isBull, double close, double atr)
{
   if(FVG_ConfBonus <= 0.0) return false;
   double proximity = 1.5 * atr;
   for(int i = 0; i < FVG_MAX; i++)
   {
      if(!g_FVGs[i].active || g_FVGs[i].mitigated) continue;
      if(g_FVGs[i].isBull != isBull) continue;
      if(close >= g_FVGs[i].bottom-proximity && close <= g_FVGs[i].top+proximity) return true;
   }
   return false;
}

bool IsNearHTFFVG(bool isBull, double close, double atr)
{
   if(!EnableHTFFVG || HTF_FVG_ConfBonus <= 0.0) return false;
   double proximity = 2.0 * atr;
   for(int i = 0; i < FVG_MAX; i++)
   {
      if(!g_FVGs_HTF[i].active || g_FVGs_HTF[i].mitigated) continue;
      if(g_FVGs_HTF[i].isBull != isBull) continue;
      if(close >= g_FVGs_HTF[i].bottom-proximity && close <= g_FVGs_HTF[i].top+proximity) return true;
   }
   return false;
}

bool IsNearActiveOB(bool isBull, double close, double atr)
{
   if(!EnableOB || OB_ConfBonus<=0.0 || atr<=0.0) return false;
   double proximity=OB_ProximityATR*atr;
   for(int i=0;i<OB_MAX;i++)
   {
      if(!g_OBs[i].active || g_OBs[i].mitigated) continue;
      if(g_OBs[i].isBull!=isBull) continue;
      if(close>=g_OBs[i].bottom-proximity && close<=g_OBs[i].top+proximity) return true;
   }
   return false;
}

bool IsNearHTFOB(bool isBull, double close, double atr)
{
   if(!EnableOB || !EnableHTFOB || HTF_OB_ConfBonus<=0.0 || atr<=0.0) return false;
   double proximity=MathMax(OB_ProximityATR,0.5)*atr;
   for(int i=0;i<OB_MAX;i++)
   {
      if(!g_OBs_HTF[i].active || g_OBs_HTF[i].mitigated) continue;
      if(g_OBs_HTF[i].isBull!=isBull) continue;
      if(close>=g_OBs_HTF[i].bottom-proximity && close<=g_OBs_HTF[i].top+proximity) return true;
   }
   return false;
}

bool HasOBFVGConfluence(bool isBull, double close, double atr)
{
   if(OB_FVG_ConfluenceBonus<=0.0) return false;
   return IsNearActiveOB(isBull,close,atr) && IsNearActiveFVG(isBull,close,atr);
}

//===================================================================
// DASHBOARD & BUTTON FUNCTIONS
//===================================================================
bool ShouldShowDashboard()
{
   if(!ShowDashboard) return false;
   if(!DashboardMasterSwitch) return true;
   if(g_ActiveDashboardInstance == 0) g_ActiveDashboardInstance = DashboardInstanceID;
   return (g_ActiveDashboardInstance == DashboardInstanceID);
}

void CreateManualTradeButton()
{
   if(ObjectFind(0,BTN_MANUAL_TRADE) >= 0) return;
   ObjectCreate(0,BTN_MANUAL_TRADE,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_CORNER,DashboardCorner);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_XDISTANCE,20);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_YDISTANCE,310);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_XSIZE,140);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_YSIZE,26);
   ObjectSetString(0,BTN_MANUAL_TRADE,OBJPROP_TEXT,g_TradingPaused?"MANUAL: OFF":"MANUAL: ON");
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_FONTSIZE,8);
   ObjectSetString(0,BTN_MANUAL_TRADE,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_COLOR,g_TradingPaused?clrCrimson:clrDodgerBlue);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_BGCOLOR,C'18,24,35');
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_BORDER_COLOR,clrDimGray);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_HIDDEN,false);
}

void CreateTrailingStopButton()
{
   if(ObjectFind(0,BTN_TRAILING_STOP) >= 0) return;
   ObjectCreate(0,BTN_TRAILING_STOP,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_CORNER,DashboardCorner);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_XDISTANCE,170);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_YDISTANCE,310);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_XSIZE,140);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_YSIZE,26);
   ObjectSetString(0,BTN_TRAILING_STOP,OBJPROP_TEXT,g_TrailingStopEnabled?"TRAILING: ON":"TRAILING: OFF");
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_FONTSIZE,8);
   ObjectSetString(0,BTN_TRAILING_STOP,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_COLOR,g_TrailingStopEnabled?clrLime:clrCrimson);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_BGCOLOR,C'18,24,35');
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_BORDER_COLOR,clrDimGray);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_HIDDEN,false);
}

void UpdateButtonStates()
{
   if(ObjectFind(0,BTN_MANUAL_TRADE)>=0)
   {
      ObjectSetString(0,BTN_MANUAL_TRADE,OBJPROP_TEXT,g_TradingPaused?"MANUAL: OFF":"MANUAL: ON");
      ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_COLOR,g_TradingPaused?clrCrimson:clrDodgerBlue);
   }
   if(ObjectFind(0,BTN_TRAILING_STOP)>=0)
   {
      ObjectSetString(0,BTN_TRAILING_STOP,OBJPROP_TEXT,g_TrailingStopEnabled?"TRAILING: ON":"TRAILING: OFF");
      ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_COLOR,g_TrailingStopEnabled?clrLime:clrCrimson);
   }
   EnsureMarketWatchPanel();
   ChartRedraw(0);
}

void DestroyMarketWatchPanel()
{
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string nm=ObjectName(0,i);
      if(StringFind(nm,MW_PFX)==0) ObjectDelete(0,nm);
   }
}

void SetDashboardBgHeight(int h)
{
   string bgName=DASH_PFX+"BG";
   if(ObjectFind(0,bgName)>=0) ObjectSetInteger(0,bgName,OBJPROP_YSIZE,h);
}

void EnsureMarketWatchPanel()
{
   if(!ShouldShowDashboard()) return;
   bool show=!g_TradingPaused;
   int compactH=ShowSessionPL?420:360;
   int expandedH=ShowSessionPL?560:500;
   SetDashboardBgHeight(show?expandedH:compactH);
   if(!show){ DestroyMarketWatchPanel(); return; }
   const int c=DashboardCorner;
   if(ObjectFind(0,MW_HDR)<0)
   {
      ObjectCreate(0,MW_HDR,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,MW_HDR,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_HDR,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,MW_HDR,OBJPROP_YDISTANCE,338);
      ObjectSetString(0,MW_HDR,OBJPROP_TEXT,"Market Watch");
      ObjectSetInteger(0,MW_HDR,OBJPROP_COLOR,clrSilver);
      ObjectSetInteger(0,MW_HDR,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,MW_HDR,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,MW_HDR,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_HDR,OBJPROP_HIDDEN,true);
   }
   if(ObjectFind(0,MW_SYM)<0)
   {
      ObjectCreate(0,MW_SYM,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,MW_SYM,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_SYM,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,MW_SYM,OBJPROP_YDISTANCE,354);
      ObjectSetInteger(0,MW_SYM,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,MW_SYM,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,MW_SYM,OBJPROP_FONT,"Arial Bold");
      ObjectSetInteger(0,MW_SYM,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_SYM,OBJPROP_HIDDEN,true);
   }
   if(ObjectFind(0,MW_CLK)<0)
   {
      ObjectCreate(0,MW_CLK,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,MW_CLK,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_CLK,OBJPROP_XDISTANCE,200);
      ObjectSetInteger(0,MW_CLK,OBJPROP_YDISTANCE,354);
      ObjectSetInteger(0,MW_CLK,OBJPROP_COLOR,clrGainsboro);
      ObjectSetInteger(0,MW_CLK,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,MW_CLK,OBJPROP_FONT,"Courier New");
      ObjectSetInteger(0,MW_CLK,OBJPROP_ALIGN,ALIGN_RIGHT);
      ObjectSetInteger(0,MW_CLK,OBJPROP_XSIZE,120);
      ObjectSetInteger(0,MW_CLK,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_CLK,OBJPROP_HIDDEN,true);
   }
   if(ObjectFind(0,BTN_MW_SELL)<0)
   {
      ObjectCreate(0,BTN_MW_SELL,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_CORNER,c);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_YDISTANCE,374);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_XSIZE,140);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_YSIZE,46);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,BTN_MW_SELL,OBJPROP_FONT,"Arial Bold");
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_BGCOLOR,C'112,32,32');
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_BORDER_COLOR,C'148,46,46');
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_ALIGN,ALIGN_CENTER);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_HIDDEN,false);
   }
   if(ObjectFind(0,MW_VOL_EDIT)<0)
   {
      ObjectCreate(0,MW_VOL_EDIT,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_XDISTANCE,64);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_YDISTANCE,428);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_XSIZE,202);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_YSIZE,26);
      ObjectSetString(0,MW_VOL_EDIT,OBJPROP_TEXT,StringFormat("Lot Size %.2f",g_MWVolume));
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_BGCOLOR,C'24,30,42');
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_BORDER_COLOR,clrDimGray);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_ALIGN,ALIGN_CENTER);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_VOL_EDIT,OBJPROP_HIDDEN,false);
   }
   if(ObjectFind(0,BTN_MW_VOLM)<0)
   {
      ObjectCreate(0,BTN_MW_VOLM,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_CORNER,c);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_YDISTANCE,428);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_XSIZE,40);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_YSIZE,26);
      ObjectSetString(0,BTN_MW_VOLM,OBJPROP_TEXT,"-");
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_BGCOLOR,C'40,45,58');
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_BORDER_COLOR,clrDimGray);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_ALIGN,ALIGN_CENTER);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_HIDDEN,false);
   }
   if(ObjectFind(0,BTN_MW_VOLP)<0)
   {
      ObjectCreate(0,BTN_MW_VOLP,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_CORNER,c);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_XDISTANCE,270);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_YDISTANCE,428);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_XSIZE,40);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_YSIZE,26);
      ObjectSetString(0,BTN_MW_VOLP,OBJPROP_TEXT,"+");
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_FONTSIZE,10);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_BGCOLOR,C'40,45,58');
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_BORDER_COLOR,clrDimGray);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_ALIGN,ALIGN_CENTER);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_HIDDEN,false);
   }
   if(ObjectFind(0,BTN_MW_BUY)<0)
   {
      ObjectCreate(0,BTN_MW_BUY,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_CORNER,c);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_XDISTANCE,170);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_YDISTANCE,374);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_XSIZE,140);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_YSIZE,46);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,BTN_MW_BUY,OBJPROP_FONT,"Arial Bold");
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_COLOR,clrWhite);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_BGCOLOR,C'28,94,56');
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_BORDER_COLOR,C'46,132,78');
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_ALIGN,ALIGN_CENTER);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_HIDDEN,false);
   }
   if(ObjectFind(0,MW_STATS)<0)
   {
      ObjectCreate(0,MW_STATS,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,MW_STATS,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_STATS,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,MW_STATS,OBJPROP_YDISTANCE,460);
      ObjectSetInteger(0,MW_STATS,OBJPROP_COLOR,clrDarkGray);
      ObjectSetInteger(0,MW_STATS,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,MW_STATS,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,MW_STATS,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_STATS,OBJPROP_HIDDEN,true);
   }
   if(ObjectFind(0,MW_LOW)<0)
   {
      ObjectCreate(0,MW_LOW,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,MW_LOW,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_LOW,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,MW_LOW,OBJPROP_YDISTANCE,480);
      ObjectSetInteger(0,MW_LOW,OBJPROP_COLOR,clrSilver);
      ObjectSetInteger(0,MW_LOW,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,MW_LOW,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,MW_LOW,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_LOW,OBJPROP_HIDDEN,true);
   }
   if(ObjectFind(0,MW_HIGH)<0)
   {
      ObjectCreate(0,MW_HIGH,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_CORNER,c);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_XDISTANCE,120);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_YDISTANCE,480);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_COLOR,clrSilver);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,MW_HIGH,OBJPROP_FONT,"Arial");
      ObjectSetInteger(0,MW_HIGH,OBJPROP_ALIGN,ALIGN_RIGHT);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_XSIZE,154);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,MW_HIGH,OBJPROP_HIDDEN,true);
   }
}

double ReadMWPanelLot()
{
   if(ObjectFind(0,MW_VOL_EDIT)>=0)
   {
      string t=ObjectGetString(0,MW_VOL_EDIT,OBJPROP_TEXT);
      StringReplace(t,"Lot:","");
      StringReplace(t,"v","");
      StringReplace(t,"▼","");
      StringTrimLeft(t);
      StringTrimRight(t);
      double v=StringToDouble(t);
      if(v>0.0) g_MWVolume=v;
   }
   double lot=NormalizeLot(g_MWVolume);
   if(lot<g_VolMin) lot=g_VolMin;
   return lot;
}

void SyncMWLotIndexFromVolume()
{
   int n=ArraySize(g_MWLotOptions);
   if(n<=0) return;
   double bestDiff=DBL_MAX;
   int bestIdx=0;
   for(int i=0;i<n;i++)
   {
      double lv=NormalizeLot(g_MWLotOptions[i]);
      double d=MathAbs(lv-g_MWVolume);
      if(d<bestDiff){ bestDiff=d; bestIdx=i; }
   }
   g_MWLotIndex=bestIdx;
}

void UpdateMWLotDropdownText()
{
   if(ObjectFind(0,MW_VOL_EDIT)>=0)
      ObjectSetString(0,MW_VOL_EDIT,OBJPROP_TEXT,StringFormat("Lot Size %.2f",g_MWVolume));
}

void StepMWLot(bool up)
{
   int n=ArraySize(g_MWLotOptions);
   if(n<=0) return;
   SyncMWLotIndexFromVolume();
   if(up) g_MWLotIndex=(g_MWLotIndex+1)%n;
   else   g_MWLotIndex=(g_MWLotIndex-1+n)%n;
   g_MWVolume=NormalizeLot(g_MWLotOptions[g_MWLotIndex]);
   if(g_MWVolume<g_VolMin) g_MWVolume=g_VolMin;
   if(g_MWVolume>g_VolMax) g_MWVolume=g_VolMax;
   UpdateMWLotDropdownText();
}

void UpdateMarketWatchPanel()
{
   if(!ShouldShowDashboard()||g_TradingPaused) return;
   if(ObjectFind(0,MW_HDR)<0) return;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   g_MWVolume=ReadMWPanelLot();
   ObjectSetString(0,MW_HDR,OBJPROP_TEXT,StringFormat("Market Watch : Symbol (%s)",_Symbol));
   ObjectSetString(0,MW_SYM,OBJPROP_TEXT,"");
   ObjectSetString(0,MW_CLK,OBJPROP_TEXT,"");
   UpdateMWLotDropdownText();
   ObjectSetString(0,BTN_MW_SELL,OBJPROP_TEXT,"SELL\n"+DoubleToString(bid,g_Digits));
   ObjectSetString(0,BTN_MW_BUY,OBJPROP_TEXT,"BUY\n"+DoubleToString(ask,g_Digits));
   long sp=(long)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double swL=SymbolInfoDouble(_Symbol,SYMBOL_SWAP_LONG);
   double swS=SymbolInfoDouble(_Symbol,SYMBOL_SWAP_SHORT);
   ObjectSetString(0,MW_STATS,OBJPROP_TEXT,
      "Spread: "+IntegerToString(sp)+"   Swap: "+DoubleToString(swL,2)+" / "+DoubleToString(swS,2));
   double dh=iHigh(_Symbol,PERIOD_D1,0);
   double dl=iLow(_Symbol,PERIOD_D1,0);
   ObjectSetString(0,MW_LOW,OBJPROP_TEXT,"LOW  "+DoubleToString(dl,g_Digits));
   ObjectSetString(0,MW_HIGH,OBJPROP_TEXT,"HIGH "+DoubleToString(dh,g_Digits));
}

void OpenMWTrade(bool isBuy)
{
   if(g_TradingPaused) return;
   if(g_DailyCapHit||g_DailyLimitHit){ Print("MW: blocked (daily cap/limit)"); return; }
   if(EnableSpread&&IsSpreadTooWide()){ Print("MW: blocked (spread)"); return; }
   if(EnableSession&&!IsSessionActive()){ Print("MW: blocked (session)"); return; }
   if(UseNewsFilter&&IsNearNewsTime()){ Print("MW: blocked (news)"); return; }
   if(AccountInfoDouble(ACCOUNT_EQUITY)<MinAccountBalance){ Print("MW: low equity"); return; }
   if(!LoadIndicators()){ Print("MW: indicators not ready"); return; }
   double atr=atrBuf[1];
   if(atr<=0.0) atr=g_LastATR;
   if(atr<=0.0){ Print("MW: ATR unavailable"); return; }
   double lot=ReadMWPanelLot();
   if(lot<g_VolMin||lot<=0.0){ Print("MW: invalid lot"); return; }
   int tp=CountPositions();
   if(isBuy)
   {
      if(CountPositionsByType(POSITION_TYPE_BUY)>=MaxBuyPositions||tp>=MaxPositionsGlobal)
      { Print("MW: buy limit"); return; }
   }
   else
   {
      if(CountPositionsByType(POSITION_TYPE_SELL)>=MaxSellPositions||tp>=MaxPositionsGlobal)
      { Print("MW: sell limit"); return; }
   }
   double price=isBuy?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double slMult,tpMult; GetDynamicSLTP(atr,slMult,tpMult);
   double tpB,tpS;
   if(UseDynamicTP)
   {
      tpB=tpS=NormalizeDouble(bbMid[1],g_Digits);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(isBuy&&tpB<=ask) tpB=NormalizeDouble(price+tpMult*atr,g_Digits);
      if(!isBuy&&tpS>=bid) tpS=NormalizeDouble(price-tpMult*atr,g_Digits);
   }
   else{ tpB=NormalizeDouble(price+tpMult*atr,g_Digits); tpS=NormalizeDouble(price-tpMult*atr,g_Digits); }
   if(isBuy)
   {
      double sl=EnforceStopLevel(ORDER_TYPE_BUY,price-slMult*atr,price);
      if(!CanOpenByGlobalRiskCap(true,lot,price,sl)) return;
      bool ok=trade.Buy(lot,_Symbol,0,sl,tpB,"JB-Algo|MW|BUY");
      if(!ok&&(trade.ResultRetcode()==10029||trade.ResultRetcode()==10030))
      { sl=EnforceStopLevel(ORDER_TYPE_BUY,sl,price); ok=trade.Buy(lot,_Symbol,0,sl,tpB,"JB-Algo|MW|BUY|RETRY"); }
      if(ok){ g_Buys++; IncrementTradeCounter(); Print("MW BUY Lot:",lot," SL:",sl," TP:",tpB);
         DrawEntryMoneyRisks(true,SymbolInfoDouble(_Symbol,SYMBOL_ASK),sl,tpB,lot); }
      else Print("MW BUY fail ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   }
   else
   {
      double sl=EnforceStopLevel(ORDER_TYPE_SELL,price+slMult*atr,price);
      if(!CanOpenByGlobalRiskCap(false,lot,price,sl)) return;
      bool ok=trade.Sell(lot,_Symbol,0,sl,tpS,"JB-Algo|MW|SELL");
      if(!ok&&(trade.ResultRetcode()==10029||trade.ResultRetcode()==10030))
      { sl=EnforceStopLevel(ORDER_TYPE_SELL,sl,price); ok=trade.Sell(lot,_Symbol,0,sl,tpS,"JB-Algo|MW|SELL|RETRY"); }
      if(ok){ g_Sells++; IncrementTradeCounter(); Print("MW SELL Lot:",lot," SL:",sl," TP:",tpS);
         DrawEntryMoneyRisks(false,SymbolInfoDouble(_Symbol,SYMBOL_BID),sl,tpS,lot); }
      else Print("MW SELL fail ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   }
}

void CreateDashboard()
{
   if(!ShouldShowDashboard()) return;
   string bgName = DASH_PFX+"BG";
   if(ObjectFind(0,bgName) < 0)
   {
      ObjectCreate(0,bgName,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,bgName,OBJPROP_CORNER,DashboardCorner);
      ObjectSetInteger(0,bgName,OBJPROP_XDISTANCE,10);
      ObjectSetInteger(0,bgName,OBJPROP_YDISTANCE,10);
      ObjectSetInteger(0,bgName,OBJPROP_XSIZE,320);
      ObjectSetInteger(0,bgName,OBJPROP_YSIZE,ShowSessionPL?420:360);
      ObjectSetInteger(0,bgName,OBJPROP_BGCOLOR,DashboardBG);
      ObjectSetInteger(0,bgName,OBJPROP_BORDER_COLOR,clrDodgerBlue);
      ObjectSetInteger(0,bgName,OBJPROP_BORDER_TYPE,BORDER_RAISED);
      ObjectSetInteger(0,bgName,OBJPROP_WIDTH,2);
      ObjectSetInteger(0,bgName,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,bgName,OBJPROP_HIDDEN,true);
   }
   string titleName = DASH_PFX+"TITLE";
   if(ObjectFind(0,titleName) < 0)
   {
      ObjectCreate(0,titleName,OBJ_LABEL,0,0,0);
      ObjectSetString(0,titleName,OBJPROP_TEXT,"JB-ALGO");
      ObjectSetInteger(0,titleName,OBJPROP_CORNER,DashboardCorner);
      ObjectSetInteger(0,titleName,OBJPROP_XDISTANCE,20);
      ObjectSetInteger(0,titleName,OBJPROP_YDISTANCE,15);
      ObjectSetInteger(0,titleName,OBJPROP_COLOR,clrGold);
      ObjectSetInteger(0,titleName,OBJPROP_FONTSIZE,DashboardFontSize+6);
      ObjectSetString(0,titleName,OBJPROP_FONT,"Times New Roman");
      ObjectSetInteger(0,titleName,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,titleName,OBJPROP_HIDDEN,true);
   }
   for(int i = 0; i < DASH_ROWS; i++)
   {
      string lblName = DASH_PFX+"LBL_"+IntegerToString(i);
      string valName = DASH_PFX+"VAL_"+IntegerToString(i);
      if(ObjectFind(0,lblName) < 0)
      {
         ObjectCreate(0,lblName,OBJ_LABEL,0,0,0);
         ObjectSetString(0,lblName,OBJPROP_TEXT,g_DashLabels[i]);
         ObjectSetInteger(0,lblName,OBJPROP_CORNER,DashboardCorner);
         ObjectSetInteger(0,lblName,OBJPROP_XDISTANCE,20);
         ObjectSetInteger(0,lblName,OBJPROP_YDISTANCE,50+i*15);
         ObjectSetInteger(0,lblName,OBJPROP_COLOR,clrLightGray);
         ObjectSetInteger(0,lblName,OBJPROP_FONTSIZE,DashboardFontSize);
         ObjectSetString(0,lblName,OBJPROP_FONT,"Courier New");
         ObjectSetInteger(0,lblName,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,lblName,OBJPROP_HIDDEN,true);
      }
      if(ObjectFind(0,valName) < 0)
      {
         ObjectCreate(0,valName,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,valName,OBJPROP_CORNER,DashboardCorner);
         ObjectSetInteger(0,valName,OBJPROP_XDISTANCE,160);
         ObjectSetInteger(0,valName,OBJPROP_YDISTANCE,50+i*15);
         ObjectSetInteger(0,valName,OBJPROP_COLOR,DashboardText);
         ObjectSetInteger(0,valName,OBJPROP_FONTSIZE,DashboardFontSize);
         ObjectSetString(0,valName,OBJPROP_FONT,"Courier New Bold");
         ObjectSetInteger(0,valName,OBJPROP_ALIGN,ALIGN_RIGHT);
         ObjectSetInteger(0,valName,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0,valName,OBJPROP_HIDDEN,true);
      }
   }
   CreateManualTradeButton();
   CreateTrailingStopButton();
   EnsureMarketWatchPanel();
   UpdateMarketWatchPanel();
   ChartRedraw(0);
}

void CleanupDashboard()
{
   for(int i=ObjectsTotal(0)-1; i>=0; i--)
   {
      string nm = ObjectName(0,i);
      if(StringFind(nm,DASH_PFX)==0 || nm==BTN_MANUAL_TRADE || nm==BTN_TRAILING_STOP || StringFind(nm,MW_PFX)==0)
         ObjectDelete(0,nm);
   }
}

int CountFVGByType(bool isBull)
{
   int cnt = 0;
   for(int i=0;i<FVG_MAX;i++)
      if(g_FVGs[i].active && !g_FVGs[i].mitigated && g_FVGs[i].isBull==isBull) cnt++;
   return cnt;
}

int CountOBByType(bool isBull)
{
   int cnt=0;
   for(int i=0;i<OB_MAX;i++)
      if(g_OBs[i].active && !g_OBs[i].mitigated && g_OBs[i].isBull==isBull) cnt++;
   return cnt;
}

void UpdateDashboard()
{
   if(!ShouldShowDashboard()) return;
   g_DashValues[2] = _Symbol;
   g_DashValues[3] = EnumToString(Period());
   g_DashValues[4] = SYMCLASS_NAMES[(int)g_SymClass];
   if(!g_WarmUpComplete)             g_DashValues[5] = "Warming...";
   else if(g_DailyCapHit)            g_DashValues[5] = "Cap Hit";
   else if(g_DailyLimitHit&&g_HitDailyTradeLimit)
      g_DashValues[5] = StringFormat("TradeLimit %d/%d",g_TodayTradeCount,MaxTradesPerDay);
   else if(g_DailyLimitHit)          g_DashValues[5] = "Loss Limit";
   else if(CheckEquityCurvePause())  g_DashValues[5] = "EqPause";
   else if(!IsSessionActive()&&EnableSession) g_DashValues[5] = "Session";
   else if(EnableSpread&&IsSpreadTooWide())   g_DashValues[5] = "Spread";
   else if(UseNewsFilter&&IsNearNewsTime())   g_DashValues[5] = "News";
   else                              g_DashValues[5] = "Active";
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double close=(bid+ask)/2.0;
   double atr=(g_LastATR>0)?g_LastATR:0.0001;
   double tmpK=0,tmpD=0,tmpPK=0,tmpPD=0;
   CalcStochRSI(tmpK,tmpD,tmpPK,tmpPD);
   bool nearBullFVG    = IsNearActiveFVG(true, close,atr);
   bool nearBearFVG    = IsNearActiveFVG(false,close,atr);
   bool nearBullHTFFVG = IsNearHTFFVG(true, close,atr);
   bool nearBearHTFFVG = IsNearHTFFVG(false,close,atr);
   bool nearBullOB     = IsNearActiveOB(true, close,atr);
   bool nearBearOB     = IsNearActiveOB(false,close,atr);
   bool nearBullHTFOB  = IsNearHTFOB(true, close,atr);
   bool nearBearHTFOB  = IsNearHTFOB(false,close,atr);
   double effOS  = RelaxSignalForTesting?MinStochOversold:Oversold;
   double effOB  = RelaxSignalForTesting?MaxStochOverbought:Overbought;
   double sellOB = effOB*MathMax(MathMin(SellBiasMultiplier,1.0),0.5);
   double buyConf=0, sellConf=0;
   if(atr>0 && ArraySize(adxBuf)>1)
   {
      double adx=adxBuf[1];
      double kOS  = (effOS>0)?MathMax(0,MathMin(1,(effOS-tmpK)/effOS)):0;
      double bbB  = (BBTolerance*atr>0)?MathMax(0,MathMin(1,(bbLow[1]+BBTolerance*atr-close)/(BBTolerance*atr))):0;
      buyConf = kOS*45+bbB*30+MathMin(1,adx/MathMax(g_P.adx_level,1))*15+(close>sarBuf[1]?10:0);
      if(nearBullFVG)    buyConf+=FVG_ConfBonus;
      if(nearBullHTFFVG) buyConf+=HTF_FVG_ConfBonus;
      if(nearBullOB)     buyConf+=OB_ConfBonus;
      if(nearBullHTFOB)  buyConf+=HTF_OB_ConfBonus;
      if(nearBullFVG && nearBullOB) buyConf+=OB_FVG_ConfluenceBonus;
      double kOB  = (100-sellOB>0)?MathMax(0,MathMin(1,(tmpK-sellOB)/(100-sellOB))):0;
      double bbS  = (BBTolerance*atr>0)?MathMax(0,MathMin(1,(close-(bbUp[1]-BBTolerance*atr))/(BBTolerance*atr))):0;
      sellConf = kOB*45+bbS*30+MathMin(1,adx/MathMax(g_P.adx_level,1))*15+(close<sarBuf[1]?10:0);
      if(nearBearFVG)    sellConf+=FVG_ConfBonus;
      if(nearBearHTFFVG) sellConf+=HTF_FVG_ConfBonus;
      if(nearBearOB)     sellConf+=OB_ConfBonus;
      if(nearBearHTFOB)  sellConf+=HTF_OB_ConfBonus;
      if(nearBearFVG && nearBearOB) sellConf+=OB_FVG_ConfluenceBonus;
   }
   buyConf  = MathMin(100,MathMax(0,buyConf));
   sellConf = MathMin(100,MathMax(0,sellConf));
   double confMinDyn=ResolveConfThreshold(adxBuf[1]);
   string cB=(buyConf>=confMinDyn)?"++":((buyConf>=40)?"~~":"--");
   string cS=(sellConf>=confMinDyn)?"++":((sellConf>=40)?"~~":"--");
   g_DashValues[6]  = StringFormat("%s %.0f%% / %s %.0f%%",cB,buyConf,cS,sellConf);
   int bullFVG=CountFVGByType(true), bearFVG=CountFVGByType(false);
   int bullOB=CountOBByType(true), bearOB=CountOBByType(false);
   g_DashValues[7]  = StringFormat("FVG B:%d/S:%d | OB B:%d/S:%d",bullFVG,bearFVG,bullOB,bearOB);
   double dailyPL   = AccountInfoDouble(ACCOUNT_EQUITY)-g_DayStartBalanceForCap;
   g_DashValues[8]  = StringFormat("%s$%.2f",(dailyPL>=0)?"+":"",(dailyPL>=0)?dailyPL:-dailyPL);
   ObjectSetInteger(0,DASH_PFX+"VAL_8",OBJPROP_COLOR,(dailyPL>=0)?clrLime:clrOrangeRed);
   double cap = ResolveDailyProfitCap();
   if(g_DailyCapHit)   g_DashValues[9]="CAP HIT";
   else if(cap>0)      g_DashValues[9]=StringFormat("$%.0f/$%.0f",dailyPL,cap);
   else                g_DashValues[9]="Unlimited";
   int totalPos=CountPositions(), buys=CountPositionsByType(POSITION_TYPE_BUY), sells=CountPositionsByType(POSITION_TYPE_SELL);
   g_DashValues[10] = StringFormat("%d (B:%d/S:%d)",totalPos,buys,sells);
   g_DashValues[11] = StringFormat("$%.2f",AccountInfoDouble(ACCOUNT_EQUITY));
   double spreadPts = (ask-bid)/_Point;
   g_DashValues[12] = StringFormat("%.1f/%.0f pts",spreadPts,g_SpreadLimit);
   g_DashValues[13] = StringFormat("%.5f",atr);
   if(ShowSessionPL)
   {
      g_DashValues[14]="";
      g_DashValues[15]=StringFormat("%dW %dL  %s$%.2f",g_SessionAsian.wins,g_SessionAsian.losses,SessionNet(g_SessionAsian)>=0?"+":"",MathAbs(SessionNet(g_SessionAsian)));
      g_DashValues[16]=StringFormat("%dW %dL  %s$%.2f",g_SessionLondon.wins,g_SessionLondon.losses,SessionNet(g_SessionLondon)>=0?"+":"",MathAbs(SessionNet(g_SessionLondon)));
      g_DashValues[17]=StringFormat("%dW %dL  %s$%.2f",g_SessionNY.wins,g_SessionNY.losses,SessionNet(g_SessionNY)>=0?"+":"",MathAbs(SessionNet(g_SessionNY)));
   }
   else
   {
      g_DashValues[14]="";
      g_DashValues[15]="Hidden";
      g_DashValues[16]="Hidden";
      g_DashValues[17]="Hidden";
   }
   g_DashValues[18]="──────────────";
   color asianClr=(g_SessionAsian.wins+g_SessionAsian.losses)==0?clrSilver:(SessionNet(g_SessionAsian)>=0?clrLime:clrOrangeRed);
   color londonClr=(g_SessionLondon.wins+g_SessionLondon.losses)==0?clrSilver:(SessionNet(g_SessionLondon)>=0?clrLime:clrOrangeRed);
   color nyClr=(g_SessionNY.wins+g_SessionNY.losses)==0?clrSilver:(SessionNet(g_SessionNY)>=0?clrLime:clrOrangeRed);
   ObjectSetInteger(0,DASH_PFX+"VAL_15",OBJPROP_COLOR,ShowSessionPL?asianClr:clrSilver);
   ObjectSetInteger(0,DASH_PFX+"VAL_16",OBJPROP_COLOR,ShowSessionPL?londonClr:clrSilver);
   ObjectSetInteger(0,DASH_PFX+"VAL_17",OBJPROP_COLOR,ShowSessionPL?nyClr:clrSilver);
   for(int i=0;i<DASH_ROWS;i++)
      ObjectSetString(0,DASH_PFX+"VAL_"+IntegerToString(i),OBJPROP_TEXT,g_DashValues[i]);
   EnsureMarketWatchPanel();
   if(!g_TradingPaused) UpdateMarketWatchPanel();
   ChartRedraw(0);
}

//===================================================================
// CHART EVENT HANDLER
//===================================================================
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_MANUAL_TRADE)
      {
         g_TradingPaused = !g_TradingPaused;
         ObjectSetInteger(0,BTN_MANUAL_TRADE,OBJPROP_STATE,false);
         UpdateButtonStates();
         Print("Manual Trade ",g_TradingPaused?"DISABLED":"ENABLED");
      }
      if(sparam == BTN_TRAILING_STOP)
      {
         g_TrailingStopEnabled = !g_TrailingStopEnabled;
         ObjectSetInteger(0,BTN_TRAILING_STOP,OBJPROP_STATE,false);
         UpdateButtonStates();
         Print("Trailing Stop ",g_TrailingStopEnabled?"ENABLED":"DISABLED");
      }
      if(sparam == BTN_MW_SELL)
      {
         ObjectSetInteger(0,BTN_MW_SELL,OBJPROP_STATE,false);
         OpenMWTrade(false);
      }
      if(sparam == BTN_MW_BUY)
      {
         ObjectSetInteger(0,BTN_MW_BUY,OBJPROP_STATE,false);
         OpenMWTrade(true);
      }
      if(sparam == BTN_MW_VOLM)
      {
         ObjectSetInteger(0,BTN_MW_VOLM,OBJPROP_STATE,false);
         StepMWLot(false);
      }
      if(sparam == BTN_MW_VOLP)
      {
         ObjectSetInteger(0,BTN_MW_VOLP,OBJPROP_STATE,false);
         StepMWLot(true);
      }
   }
}

//===================================================================
// NEWS FILTER HELPER
//===================================================================
bool IsNearNewsTime()
{
   if(!UseNewsFilter || ArraySize(g_NewsTimes)==0) return false;
   datetime now = TimeGMT();
   for(int i=0;i<ArraySize(g_NewsTimes);i++)
   {
      datetime nt = g_NewsTimes[i].eventTime;
      if(now>=nt-AvoidTradingMinutesBeforeNews*60 && now<=nt+AvoidTradingMinutesAfterNews*60)
         return true;
   }
   return false;
}

//===================================================================
// DIAGNOSTICS HELPER
//===================================================================
void DiagPrint(string msg)
{
   if(DiagnosticsMode) Print("[DIAG] ",TimeToString(TimeCurrent(),TIME_SECONDS)," | ",msg);
}

//===================================================================
// ENTRY $ RISK / REWARD (visual)
//===================================================================
void DrawEntryMoneyRisks(bool isBuy, double entry, double sl, double tp, double lot)
{
   if(!ShowEntryMoneyRisks||lot<=0.0) return;
   double pnlSL=0.0, pnlTP=0.0;
   ENUM_ORDER_TYPE ot=isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!OrderCalcProfit(ot,_Symbol,lot,entry,sl,pnlSL)) return;
   if(!OrderCalcProfit(ot,_Symbol,lot,entry,tp,pnlTP)) return;
   double riskUSD=MathAbs(pnlSL);
   double rewUSD=MathAbs(pnlTP);
   string name=OBJ_PFX+"ENTRY_RR";
   if(ObjectFind(0,name)<0)
   {
      ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_LOWER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,18);
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,name,OBJPROP_FONT,"Arial Bold");
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
   }
   ObjectSetString(0,name,OBJPROP_TEXT,StringFormat("Last open  Risk $%.2f  |  Reward $%.2f  (%s)",riskUSD,rewUSD,isBuy?"BUY":"SELL"));
   ObjectSetInteger(0,name,OBJPROP_COLOR,(rewUSD>=riskUSD)?clrLime:clrGold);
   ChartRedraw(0);
}

//===================================================================
// DRAW SIGNAL ICON
//===================================================================
void DrawSignalIcon(bool isBuy, datetime barTime, double barHigh, double barLow,
                    double atr, double adxVal, double kVal, double dVal,
                    double confidence = 0.0)
{
   if(!ShowSignalArrows) return;
   g_IconCount++;
   string id=IntegerToString(g_IconCount);
   string nameT=OBJ_PFX+"ICO_T_"+id, nameB=OBJ_PFX+"ICO_B_"+id;
   double offset=MathMax(IconOffsetATR*atr,12.0*_Point);
   offset=MathMax(offset,0.5*atr);
   double yPos=isBuy?(barLow-offset):(barHigh+offset);
   color tc=isBuy?BuyIconColor:SellIconColor, bc=isBuy?BuyIconBG:SellIconBG;
   string lbl=isBuy?"B":"S";
   string confStr=(confidence>0.0)?(" Conf:"+DoubleToString(confidence,0)+"%"):"";
   string tooltip=(isBuy?"BUY":"SELL")+confStr+" ADX:"+DoubleToString(adxVal,1)+" K:"+DoubleToString(kVal,1)+" D:"+DoubleToString(dVal,1);
   if(ObjectFind(0,nameT)>=0) ObjectDelete(0,nameT);
   if(ObjectFind(0,nameB)>=0) ObjectDelete(0,nameB);
   if(ObjectCreate(0,nameT,OBJ_TEXT,0,barTime,yPos))
   {
      ObjectSetString(0,nameT,OBJPROP_TEXT,lbl);
      ObjectSetString(0,nameT,OBJPROP_FONT,"Arial Black");
      ObjectSetInteger(0,nameT,OBJPROP_FONTSIZE,IconFontSize+2);
      ObjectSetInteger(0,nameT,OBJPROP_COLOR,tc);
      ObjectSetInteger(0,nameT,OBJPROP_ANCHOR,ANCHOR_CENTER);
      ObjectSetInteger(0,nameT,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nameT,OBJPROP_HIDDEN,false);
      ObjectSetString(0,nameT,OBJPROP_TOOLTIP,tooltip);
   }
   double boxH=MathMax(atr*0.22,14.0*_Point);
   int ps=PeriodSeconds(PERIOD_CURRENT);
   datetime tL=(datetime)(barTime-ps/4), tR=(datetime)(barTime+ps/4);
   if(ObjectCreate(0,nameB,OBJ_RECTANGLE,0,tL,yPos+boxH/2.0,tR,yPos-boxH/2.0))
   {
      ObjectSetInteger(0,nameB,OBJPROP_COLOR,bc);
      ObjectSetInteger(0,nameB,OBJPROP_FILL,true);
      ObjectSetInteger(0,nameB,OBJPROP_BACK,false);
      ObjectSetInteger(0,nameB,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,nameB,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,nameB,OBJPROP_HIDDEN,false);
   }
   ChartRedraw(0);
}

void CleanupObjects()
{
   for(int i=ObjectsTotal(0)-1; i>=0; i--)
   { string nm=ObjectName(0,i); if(StringFind(nm,OBJ_PFX)==0) ObjectDelete(0,nm); }
}

//===================================================================
// SAFE BUFFER COPY
//===================================================================
bool SafeCopyBuffer(int handle, int bufNum, int start, int count, double &arr[])
{
   int copied = CopyBuffer(handle,bufNum,start,count,arr);
   if(copied < count)
   {
      static datetime lastWarn=0;
      if(TimeCurrent()-lastWarn>60)
      { Print("WARN: CopyBuffer got ",copied,"/",count," handle ",handle," err=",GetLastError()); lastWarn=TimeCurrent(); }
      return (copied > 0);
   }
   return true;
}

//===================================================================
// TICKET ARRAY CLEANUP
//===================================================================
void CleanupTicketArrays()
{
   for(int i=ArraySize(g_PartialDoneTickets)-1; i>=0; i--)
   {
      ulong t=g_PartialDoneTickets[i];
      if(!PositionSelectByTicket(t))
      {
         int sz=ArraySize(g_PartialDoneTickets);
         for(int j=i;j<sz-1;j++) g_PartialDoneTickets[j]=g_PartialDoneTickets[j+1];
         ArrayResize(g_PartialDoneTickets,sz-1);
      }
   }
   for(int i=ArraySize(g_BreakevenDoneTickets)-1; i>=0; i--)
   {
      ulong t=g_BreakevenDoneTickets[i];
      if(!PositionSelectByTicket(t))
      {
         int sz=ArraySize(g_BreakevenDoneTickets);
         for(int j=i;j<sz-1;j++) g_BreakevenDoneTickets[j]=g_BreakevenDoneTickets[j+1];
         ArrayResize(g_BreakevenDoneTickets,sz-1);
      }
   }
}

//===================================================================
// ENFORCE STOP LEVEL
//===================================================================
double EnforceStopLevel(ENUM_ORDER_TYPE type, double rawSL, double ref)
{
   double minDist = MathMax(g_StopsLvlPrice, 5.0*_Point);
   if(minDist < 2*_Point) minDist = 2*_Point;
   double sl = rawSL;
   if(type==ORDER_TYPE_BUY)  { double mx=ref-minDist; if(sl>mx) sl=mx; }
   else                      { double mn=ref+minDist; if(sl<mn) sl=mn; }
   return NormalizeDouble(sl,g_Digits);
}

//===================================================================
// CALC LOT
//===================================================================
double CalcLot(double atr)
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq < MinAccountBalance) return 0.0;
   if(ForceFixedLotOnSmallAcct && eq<100.0){ Print("SmallAcct fixed 0.01"); return NormalizeLot(0.01); }
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double slPoints=(atr>0.0)?(g_P.atr_sl_multi*atr/_Point):0.0;
   double lpl=(tv>0.0 && ts>0.0 && slPoints>0.0)?(tv/ts)*slPoints:0.0; // estimated loss per 1.0 lot at SL
   double lot;
   if(UseRiskPercent && atr>0)
   {
      double rA=eq*g_P.risk_percent/100.0;
      double commissionPerLot=MathMax(0.0,CommissionPerLotRoundTrip);
      if(EnableHardRiskCaps)
      {
         double usdCap=MathMax(0.0,(UseMarketProfile&&g_P.max_risk_usd>0.0)?g_P.max_risk_usd:MaxRiskUSDPerTrade);
         double pctCap=eq*MathMax(0.0,MaxRiskPctEquityPerTrade)/100.0;
         double hardCap=(usdCap>0.0&&pctCap>0.0)?MathMin(usdCap,pctCap):MathMax(usdCap,pctCap);
         if(hardCap>0.0) rA=MathMin(rA,hardCap);
      }
      if(lpl<=0.0001){ Print("WARN lossPerLot too small: ",lpl," using min lot"); lot=g_VolMin; }
      else
      {
         double effLossPerLot=lpl+commissionPerLot;
         if(rA<=commissionPerLot){ Print("Skip trade: risk budget consumed by commission."); return 0.0; }
         lot=rA/effLossPerLot;
         if(lot>g_VolMax*0.9){ Print("WARN lot capped to ",g_VolMax*0.9); lot=g_VolMax*0.9; }
      }
   }
   else lot=LotSize;
   if(EnableHardRiskCaps && lpl>0.0001)
   {
      double usdCap=MathMax(0.0,(UseMarketProfile&&g_P.max_risk_usd>0.0)?g_P.max_risk_usd:MaxRiskUSDPerTrade);
      double pctCap=eq*MathMax(0.0,MaxRiskPctEquityPerTrade)/100.0;
      double hardCap=(usdCap>0.0&&pctCap>0.0)?MathMin(usdCap,pctCap):MathMax(usdCap,pctCap);
      if(hardCap>0.0)
      {
         double capLot=hardCap/lpl;
         if(capLot>0.0 && lot>capLot) lot=capLot;
      }
   }
   lot=MathMin(lot,MaxLotHardCap);
   if(EnableDrawdownLotScaling&&g_MaxEquity>0.0)
   {
      double ddPct=MathMax(0.0,(g_MaxEquity-eq)*100.0/g_MaxEquity);
      double factor=1.0;
      if(ddPct>=DrawdownStep2Pct&&DrawdownStep2Pct>0.0) factor=MathMax(0.01,DrawdownStep2LotFactor);
      else if(ddPct>=DrawdownStep1Pct&&DrawdownStep1Pct>0.0) factor=MathMax(0.01,DrawdownStep1LotFactor);
      if(factor<1.0)
      {
         lot*=factor;
         if(ShowSignals) Print("DD lot scaling: DD=",DoubleToString(ddPct,2),"% factor=",DoubleToString(factor,2));
      }
   }
   return NormalizeLot(lot);
}

double CurrentOpenRiskUSD_AllSymbols()
{
   double totalRisk=0.0;
   int total=(int)PositionsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!t) continue;
      string cmt=PositionGetString(POSITION_COMMENT);
      long mg=PositionGetInteger(POSITION_MAGIC);
      bool ours=(StringFind(cmt,"JB-Algo")>=0)||(mg==g_ActualMagicNumber);
      if(!ours) continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      double vol=PositionGetDouble(POSITION_VOLUME);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      if(vol<=0.0||sl<=0.0) continue;
      long pt=PositionGetInteger(POSITION_TYPE);
      ENUM_ORDER_TYPE ot=(pt==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
      double pnlSL=0.0;
      if(!OrderCalcProfit(ot,sym,vol,op,sl,pnlSL)) continue;
      totalRisk+=MathAbs(pnlSL);
   }
   return totalRisk;
}

bool CanOpenByGlobalRiskCap(bool isBuy, double lot, double entry, double sl)
{
   double capUSD=ResolveGlobalRiskCapUSD();
   if((capUSD<=0.0)&&(MaxOpenRiskPctEq_AllSymbols<=0.0)) return true;
   ENUM_ORDER_TYPE ot=isBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   double pnlSL=0.0;
   if(!OrderCalcProfit(ot,_Symbol,lot,entry,sl,pnlSL)) return true;
   double nextRisk=MathAbs(pnlSL);
   double curRisk=CurrentOpenRiskUSD_AllSymbols();
   double hardUSD=DBL_MAX;
   if(capUSD>0.0) hardUSD=MathMin(hardUSD,capUSD);
   if(MaxOpenRiskPctEq_AllSymbols>0.0)
   {
      double pctCap=AccountInfoDouble(ACCOUNT_EQUITY)*MaxOpenRiskPctEq_AllSymbols/100.0;
      hardUSD=MathMin(hardUSD,pctCap);
   }
   if(hardUSD==DBL_MAX) return true;
   if(curRisk+nextRisk>hardUSD)
   {
      Print("Global risk cap block: current $",DoubleToString(curRisk,2),
            " + next $",DoubleToString(nextRisk,2),
            " > cap $",DoubleToString(hardUSD,2));
      return false;
   }
   return true;
}

double GetPartialCloseTriggerATR(double atr)
{
   double p=ResolvePartialTPMulti();
   if(!DynamicPartialCloseByVolRegime||!EnableDynamicATR||ArraySize(atrMaBuf)<2) return p;
   double avgATR=atrMaBuf[1];
   if(avgATR<=0.0||atr<=0.0) return p;
   double ratio=atr/avgATR;
   if(ratio>1.3) return PartialTP_HighVol_Multi;
   if(ratio<0.7) return PartialTP_LowVol_Multi;
   return p;
}

//===================================================================
// NORMALIZE LOT  [FIX-Q retained from v5.23]
//===================================================================
double NormalizeLot(double raw)
{
   int lotDigits=(int)MathRound(-MathLog10(MathMax(g_VolStep,1e-8)));
   return NormalizeDouble(MathMax(MathMin(MathFloor(raw/g_VolStep)*g_VolStep,g_VolMax),g_VolMin),lotDigits);
}

//===================================================================
// DETECT FILL MODE
//===================================================================
ENUM_ORDER_TYPE_FILLING DetectFillMode()
{
   uint f=(uint)SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((f&ORDER_FILLING_RETURN)!=0){ Print("Fill:RETURN"); return ORDER_FILLING_RETURN; }
   if((f&ORDER_FILLING_FOK)!=0)   { Print("Fill:FOK");    return ORDER_FILLING_FOK; }
   Print("Fill:IOC"); return ORDER_FILLING_IOC;
}

//===================================================================
// COUNT POSITIONS
//===================================================================
int CountPositions()
{
   int n=0, total=(int)PositionsTotal();
   for(int i=total-1;i>=0;i--)
   { ulong t=PositionGetTicket(i); if(t&&PositionGetString(POSITION_SYMBOL)==_Symbol&&PositionGetInteger(POSITION_MAGIC)==g_ActualMagicNumber) n++; }
   return n;
}
int CountPositionsByType(long pt)
{
   int n=0, total=(int)PositionsTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!t) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=g_ActualMagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE)==pt) n++;
   }
   return n;
}

// [WARN FIXED] uint → int so ArraySize() comparison has no type loss
bool IsPartialDone(ulong t)
{
   int sz=ArraySize(g_PartialDoneTickets);
   for(int i=0;i<sz;i++) if(g_PartialDoneTickets[i]==t) return true;
   return false;
}
bool IsBreakevenDone(ulong t)
{
   int sz=ArraySize(g_BreakevenDoneTickets);
   for(int i=0;i<sz;i++) if(g_BreakevenDoneTickets[i]==t) return true;
   return false;
}
void MarkPartialDone(ulong t)
{
   if(IsPartialDone(t)) return;
   int n=ArraySize(g_PartialDoneTickets);
   ArrayResize(g_PartialDoneTickets,n+1);
   g_PartialDoneTickets[n]=t;
}
void MarkBreakevenDone(ulong t)
{
   if(IsBreakevenDone(t)) return;
   int n=ArraySize(g_BreakevenDoneTickets);
   ArrayResize(g_BreakevenDoneTickets,n+1);
   g_BreakevenDoneTickets[n]=t;
}

//===================================================================
// PURGE TICKET
//===================================================================
void PurgeTicket(ulong ticket)
{
   int sz1=ArraySize(g_PartialDoneTickets);
   for(int i=0;i<sz1;i++)
   {
      if(g_PartialDoneTickets[i]==ticket)
      { for(int j=i;j<sz1-1;j++) g_PartialDoneTickets[j]=g_PartialDoneTickets[j+1]; ArrayResize(g_PartialDoneTickets,sz1-1); break; }
   }
   int sz2=ArraySize(g_BreakevenDoneTickets);
   for(int i=0;i<sz2;i++)
   {
      if(g_BreakevenDoneTickets[i]==ticket)
      { for(int j=i;j<sz2-1;j++) g_BreakevenDoneTickets[j]=g_BreakevenDoneTickets[j+1]; ArrayResize(g_BreakevenDoneTickets,sz2-1); break; }
   }
}

//===================================================================
// CHECK DAILY RESET
//===================================================================
void CheckDayReset()
{
   datetime today=(datetime)TodayAsDouble();
   if(today!=g_LastDay)
   {
      g_LastDay=today;
      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      g_DayStartBalanceForCap=eq; g_DayStartBalance=eq; g_DayStartEquityForLossUSD=eq;
      WriteCapGV(GV_DayStartBal(),g_DayStartBalanceForCap);
      WriteCapGV(GV_CapDay(),(double)today);
      WriteCapGV(GV_CapHit(),0.0);
      g_DailyLimitHit=false; g_DailyCapHit=false;
      g_ConsecLossesToday=0; g_ConsecLossBreakerHit=false;
      g_HitDailyTradeLimit=false;
      g_TodayTradeCount=0; g_TodayTradeCountDate=today;
      g_SessionAsian.grossProfit=0.0;  g_SessionAsian.grossLoss=0.0;  g_SessionAsian.wins=0;  g_SessionAsian.losses=0;  g_SessionAsian.lastReset=today;
      g_SessionLondon.grossProfit=0.0; g_SessionLondon.grossLoss=0.0; g_SessionLondon.wins=0; g_SessionLondon.losses=0; g_SessionLondon.lastReset=today;
      g_SessionNY.grossProfit=0.0;     g_SessionNY.grossLoss=0.0;     g_SessionNY.wins=0;     g_SessionNY.losses=0;     g_SessionNY.lastReset=today;
      Print("New trading day. Start Equity: $",DoubleToString(eq,2));
   }
}

void UpdateSessionStats(SessionStats &st, double profit)
{
   if(profit>=0.0){ st.grossProfit+=profit; st.wins++; }
   else           { st.grossLoss+=MathAbs(profit); st.losses++; }
}

double SessionNet(SessionStats &st)
{
   return st.grossProfit-st.grossLoss;
}

//===================================================================
// CHECK DAILY PROFIT CAP
//===================================================================
void CheckDailyProfitCap()
{
   if(!EnableDailyProfitCap||g_DailyCapHit) return;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double profit=eq-g_DayStartBalanceForCap;
   double cap=ResolveDailyProfitCap();
   if(profit<cap) return;
   CloseAllSymbolPositions("DailyProfitCap");
   g_DailyCapHit=true;
   WriteCapGV(GV_CapHit(),1.0);
   Print("DAILY PROFIT CAP HIT! +$",DoubleToString(profit,2)," (cap=$",DoubleToString(cap,2),")");
}

//===================================================================
// CHECK DAILY LOSS LIMIT (USD)
//===================================================================
void CheckDailyLossUSD()
{
   if(!EnableDailyLimit || g_DailyLimitHit) return;
   double lossToday=g_DayStartEquityForLossUSD-AccountInfoDouble(ACCOUNT_EQUITY);
   double usdLimit=EnableDailyLossUSD?MathMax(0.0,MaxDailyLossUSD):DBL_MAX;
   double dailyLossPct=ResolveDailyLossPercent();
   double pctLimit=(dailyLossPct>0.0&&g_DayStartBalance>0.0)?(g_DayStartBalance*dailyLossPct/100.0):DBL_MAX;
   double hardLimit=MathMin(usdLimit,pctLimit);
   if(hardLimit==DBL_MAX) return;
   if(lossToday>=hardLimit)
   {
      CloseAllSymbolPositions("DailyLossFloor");
      g_DailyLimitHit=true;
      g_HitDailyTradeLimit=false;
      static datetime lastLossFloorPrintBar=0;
      datetime curBar=iTime(_Symbol,PERIOD_CURRENT,0);
      if(curBar!=lastLossFloorPrintBar)
      {
         Print("DAILY LOSS FLOOR HIT! Loss:-$",DoubleToString(lossToday,2),
               " (floor=$",DoubleToString(hardLimit,2),
               " | USD=",EnableDailyLossUSD?DoubleToString(usdLimit,2):"OFF",
               " | PCT=",DoubleToString(pctLimit,2),")");
         lastLossFloorPrintBar=curBar;
      }
   }
}

//===================================================================
// CHECK DAILY TRADE COUNT LIMIT
//===================================================================
void CheckDailyTradeLimit()
{
   if(!EnableDailyTradeLimit) return;
   datetime today=(datetime)TodayAsDouble();
   if(today!=g_TodayTradeCountDate){ g_TodayTradeCountDate=today; g_TodayTradeCount=0; }
   if(g_TodayTradeCount>=MaxTradesPerDay&&!g_DailyLimitHit)
   {
      g_DailyLimitHit=true;
      g_HitDailyTradeLimit=true;
      Print("DAILY TRADE LIMIT HIT: ",g_TodayTradeCount,"/",MaxTradesPerDay," — no more trades until next day reset.");
   }
}

void IncrementTradeCounter() { if(EnableDailyTradeLimit) g_TodayTradeCount++; }

void CloseAllSymbolPositions(string reason)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!t) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=g_ActualMagicNumber) continue;
      if(trade.PositionClose(t)) Print(reason," closed ",t);
   }
}

void CheckFridayClose()
{
   if(!CloseFridayEOD) return;
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   if(dt.day_of_week!=5||dt.hour<FridayCloseGMT) return;
   CloseAllSymbolPositions("FridayEOD");
}

string DealReasonToText(long reason)
{
   switch((int)reason)
   {
      case DEAL_REASON_CLIENT:   return "CLIENT";
      case DEAL_REASON_MOBILE:   return "MOBILE";
      case DEAL_REASON_WEB:      return "WEB";
      case DEAL_REASON_EXPERT:   return "EXPERT";
      case DEAL_REASON_SL:       return "SL";
      case DEAL_REASON_TP:       return "TP";
      case DEAL_REASON_SO:       return "STOP_OUT";
      case DEAL_REASON_ROLLOVER: return "ROLLOVER";
      case DEAL_REASON_VMARGIN:  return "VMARGIN";
      case DEAL_REASON_SPLIT:    return "SPLIT";
      default:                   return "UNKNOWN";
   }
}

void DrawCloseMarker(ulong dealTicket, datetime t, double price, double pnl, string reasonText)
{
   if(!ShowCloseMarkers) return;
   string name = OBJ_PFX + "CLS_" + IntegerToString((int)dealTicket);
   if(ObjectFind(0,name)>=0) ObjectDelete(0,name);
   if(!ObjectCreate(0,name,OBJ_TEXT,0,t,price)) return;
   color c = (pnl>=0.0)?CloseWinColor:CloseLossColor;
   ObjectSetString(0,name,OBJPROP_TEXT,"X");
   ObjectSetString(0,name,OBJPROP_FONT,"Arial Black");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,IconFontSize+1);
   ObjectSetInteger(0,name,OBJPROP_COLOR,c);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_CENTER);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,
      "CLOSE " + reasonText + " PnL:" + DoubleToString(pnl,2));
}

//===================================================================
// ON TRADE TRANSACTION
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) return;
   if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=g_ActualMagicNumber) return;
   long dealReason=HistoryDealGetInteger(trans.deal,DEAL_REASON);
   long dealType=HistoryDealGetInteger(trans.deal,DEAL_TYPE);
   double profit=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+
                 HistoryDealGetDouble(trans.deal,DEAL_SWAP)+
                 HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
   datetime dealTime=(datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);
   double dealPrice=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
   string reasonTxt=DealReasonToText(dealReason);
   ulong posId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   PurgeTicket(posId);
   MqlDateTime dt; TimeToStruct(dealTime,dt);
   int gmtHour=dt.hour-ServerTimeOffsetGMT;
   while(gmtHour<0) gmtHour+=24;
   while(gmtHour>=24) gmtHour-=24;
   if(gmtHour>=0  && gmtHour<8)  UpdateSessionStats(g_SessionAsian,profit);
   if(gmtHour>=8  && gmtHour<21) UpdateSessionStats(g_SessionLondon,profit);
   if(gmtHour>=13 && gmtHour<21) UpdateSessionStats(g_SessionNY,profit);
   g_Total++; g_RunningEquity+=profit;
   if(g_RunningEquity>g_MaxEquity) g_MaxEquity=g_RunningEquity;
   if(g_MaxEquity>0&&g_RunningEquity<g_MinEquityAfterPeak) g_MinEquityAfterPeak=g_RunningEquity;
   g_SumReturns+=profit; g_SumReturnsSquared+=profit*profit;
   if(g_ConfTakenCount<1000&&g_LastTradeConfidence>=0)
   {
      g_AvgConfTakenTrades=(g_AvgConfTakenTrades*g_ConfTakenCount+g_LastTradeConfidence)/(g_ConfTakenCount+1);
      g_ConfTakenCount++; g_LastTradeConfidence=-1.0;
   }
   if(profit>0)
   { g_Wins++;g_GrossProfit+=profit;if(profit>g_MaxWin)g_MaxWin=profit;
     g_CurrConsec=(g_LastResult==1)?g_CurrConsec+1:1; if(g_CurrConsec>g_MaxConsecWin)g_MaxConsecWin=g_CurrConsec; g_LastResult=1; }
   else
   { g_Losses++;g_GrossLoss+=MathAbs(profit);if(MathAbs(profit)>g_MaxLoss)g_MaxLoss=MathAbs(profit);
     g_CurrConsec=(g_LastResult==-1)?g_CurrConsec+1:1; if(g_CurrConsec>g_MaxConsecLoss)g_MaxConsecLoss=g_CurrConsec; g_LastResult=-1; }
   if(profit<0.0) g_ConsecLossesToday++; else g_ConsecLossesToday=0;
   if(EnableConsecLossBreaker && !g_ConsecLossBreakerHit && g_ConsecLossesToday>=MathMax(1,MaxConsecLossesPerDay))
   {
      g_ConsecLossBreakerHit=true;
      Print("CONSECUTIVE LOSS BREAKER HIT: ",g_ConsecLossesToday," losses in a row today.");
   }
   UpdateWFOStats(profit);
   DrawCloseMarker((ulong)trans.deal,dealTime,dealPrice,profit,reasonTxt);
   if(ShowStats)
   { double wr=(g_Total>0)?(double)g_Wins/g_Total*100.0:0;
     string side=(dealType==DEAL_TYPE_BUY?"BUY":
                 (dealType==DEAL_TYPE_SELL?"SELL":"N/A"));
     Print("Deal#",g_Total," ",side,
           (profit>0?" WIN $":" LOSS $"),DoubleToString(profit,2),
           " Reason:",reasonTxt,
           " WR:",DoubleToString(wr,1),"% W:",g_Wins," L:",g_Losses); }
}

//===================================================================
// CALC STOCHRSI
//===================================================================
bool CalcStochRSI(double &oK, double &oD, double &pK, double &pD)
{
   int rc=StochK_Smooth+StochD_Smooth+10, need=rc+StochRSI_Period+2, loaded=ArraySize(rsiBuf);
   if(loaded<need){ g_StochFailShortBuffer++; return false; }
   int wl=StochRSI_Period, se=rc+wl, ds=wl+4;
   int maxDq[], minDq[]; ArrayResize(maxDq,ds); ArrayResize(minDq,ds);
   int mh=0,mt=0,nh=0,nt=0;
   double rawK[]; ArrayResize(rawK,rc);
   for(int idx=1;idx<se;idx++)
   {
      if(idx>=loaded){ g_StochFailBounds++; return false; }
      while(mh<mt&&mt>0&&rsiBuf[maxDq[mt-1]]<=rsiBuf[idx]) mt--;
      if(mt>=ds){ g_StochFailDeque++; return false; } maxDq[mt++]=idx;
      while(nh<nt&&nt>0&&rsiBuf[minDq[nt-1]]>=rsiBuf[idx]) nt--;
      if(nt>=ds){ g_StochFailDeque++; return false; } minDq[nt++]=idx;
      int ws=idx-wl+1; if(maxDq[mh]<ws) mh++; if(minDq[nh]<ws) nh++;
      if(idx<wl) continue;
      int slot=idx-wl; if(slot>=rc) break;
      double hi=rsiBuf[maxDq[mh]],lo=rsiBuf[minDq[nh]],rng=hi-lo;
      rawK[slot]=(rng>0.0001)?((rsiBuf[slot+1]-lo)/rng)*100.0:50.0;
   }
   int skc=StochD_Smooth+8; double sk[]; ArrayResize(sk,skc);
   double kSum=0;
   for(int j=0;j<StochK_Smooth;j++){ if(j>=rc){ g_StochFailBounds++; return false; } kSum+=rawK[j]; }
   sk[0]=kSum/StochK_Smooth;
   for(int i=1;i<skc;i++)
   { int a=i+StochK_Smooth-1; if(a>=rc){ g_StochFailBounds++; return false; } kSum+=rawK[a]-rawK[i-1]; sk[i]=kSum/StochK_Smooth; }
   double sd=0;
   for(int i=0;i<StochD_Smooth;i++){ if(i>=ArraySize(sk)){ g_StochFailBounds++; return false; } sd+=sk[i]; }
   oK=sk[0]; oD=sd/StochD_Smooth;
   if(ArraySize(sk)<StochD_Smooth+1){ g_StochFailBounds++; return false; }
   double ps=0; for(int i=1;i<=StochD_Smooth;i++) ps+=sk[i];
   pK=sk[1]; pD=ps/StochD_Smooth;
   return true;
}

//===================================================================
// LOAD INDICATORS
//===================================================================
bool LoadIndicators()
{
   int safeN=MathMax(StochRSI_Period+StochK_Smooth+StochD_Smooth+30,100);
   if(!SafeCopyBuffer(hSAR_Entry,  0,0,10,sarBuf))    return false;
   if(!SafeCopyBuffer(hSAR_HTF,    0,0,5, htfSarBuf)) return false;
   if(!SafeCopyBuffer(hBB,         1,0,5, bbUp))       return false;
   if(!SafeCopyBuffer(hBB,         0,0,5, bbMid))      return false;
   if(!SafeCopyBuffer(hBB,         2,0,5, bbLow))      return false;
   if(!SafeCopyBuffer(hRSI,        0,0,safeN,rsiBuf))  return false;
   if(!SafeCopyBuffer(hATR,        0,0,5, atrBuf))     return false;
   if(!SafeCopyBuffer(hATR_MA_Regime,0,0,5,atrMaBuf))  return false;
   if(!SafeCopyBuffer(hADX,        0,0,5, adxBuf))     return false;
   if(!SafeCopyBuffer(hADX,        1,0,5, diPlusBuf))  return false;
   if(!SafeCopyBuffer(hADX,        2,0,5, diMinusBuf)) return false;
   return true;
}

bool IsSpreadTooWide()
{
   double sp=(SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/_Point;
   if(sp>g_SpreadLimit){ if(ShowSignals) Print("Spread:",DoubleToString(sp,1),">",DoubleToString(g_SpreadLimit,1)," skip"); return true; }
   return false;
}

//===================================================================
// SESSION FILTER
//===================================================================
bool IsSessionActive()
{
   if(g_SymClass==SYMCLASS_CRYPTO&&IgnoreSessionForCrypto) return true;
   MqlDateTime dt; TimeToStruct(TimeGMT(),dt);
   if(ServerTimeOffsetGMT!=0){ dt.hour=(dt.hour+ServerTimeOffsetGMT)%24; if(dt.hour<0) dt.hour+=24; }
   if(dt.day_of_week==0||dt.day_of_week==6) return false;
   if(g_P.session_start==0&&g_P.session_end==24) return true;
   return(dt.hour>=g_P.session_start&&dt.hour<g_P.session_end);
}

bool CheckVolume()
{
   long va[]; ArraySetAsSeries(va,true);
   if(CopyTickVolume(_Symbol,PERIOD_CURRENT,0,VolMA_Period+2,va)<=0) return true;
   double mv=0; for(int i=1;i<=VolMA_Period;i++) mv+=(double)va[i]; mv/=VolMA_Period;
   return(mv>0)&&((double)va[1]>=VolMA_Multi*mv);
}

//===================================================================
// DYNAMIC ATR MULTIPLIERS
//===================================================================
void GetDynamicSLTP(double atr, double &slMult, double &tpMult)
{
   slMult=g_P.atr_sl_multi; tpMult=g_P.atr_tp_multi;
   if(!EnableDynamicATR||ArraySize(atrMaBuf)<2) return;
   double avgATR=atrMaBuf[1]; if(avgATR<=0) avgATR=atr;
   double ratio=atr/avgATR;
   if(ratio>1.3)       { slMult=HighVol_SL_Multi; tpMult=HighVol_TP_Multi; }
   else if(ratio<0.7)  { slMult=LowVol_SL_Multi;  tpMult=LowVol_TP_Multi;  }
}

double GetTrendComponentMultiplier(double adx)
{
   if(!UseADXTrendWeighting) return 1.0;
   if(adx>=ADX_TrendStrong) return MathMax(0.1,ADX_TrendStrongMult);
   if(adx<ADX_TrendWeak) return MathMax(0.1,ADX_TrendWeakMult);
   return 1.0;
}

double CalcFVGProximityBonus(bool isBull, double close, double atr, bool useHTF)
{
   if(atr<=0.0) return 0.0;
   double base=useHTF?HTF_FVG_ConfBonus:FVG_ConfBonus;
   if(base<=0.0) return 0.0;
   double best=0.0;
   if(useHTF)
   {
      for(int i=0;i<ArraySize(g_FVGs_HTF);i++)
      {
         if(!g_FVGs_HTF[i].active||g_FVGs_HTF[i].mitigated||g_FVGs_HTF[i].isBull!=isBull) continue;
         double mid=(g_FVGs_HTF[i].top+g_FVGs_HTF[i].bottom)*0.5;
         double dATR=MathAbs(close-mid)/atr;
         double w=0.0;
         if(!UseDistanceWeightedFVG) w=1.0;
         else if(dATR<=FVG_FullBonusDistATR) w=1.0;
         else if(dATR<=FVG_HalfBonusDistATR) w=0.5;
         if(w>best) best=w;
      }
   }
   else
   {
      for(int i=0;i<ArraySize(g_FVGs);i++)
      {
         if(!g_FVGs[i].active||g_FVGs[i].mitigated||g_FVGs[i].isBull!=isBull) continue;
         double mid=(g_FVGs[i].top+g_FVGs[i].bottom)*0.5;
         double dATR=MathAbs(close-mid)/atr;
         double w=0.0;
         if(!UseDistanceWeightedFVG) w=1.0;
         else if(dATR<=FVG_FullBonusDistATR) w=1.0;
         else if(dATR<=FVG_HalfBonusDistATR) w=0.5;
         if(w>best) best=w;
      }
   }
   return base*best;
}

double CalcOBProximityBonus(bool isBull, double close, double atr, bool useHTF)
{
   if(!EnableOB || atr<=0.0) return 0.0;
   double base=useHTF?HTF_OB_ConfBonus:OB_ConfBonus;
   if(base<=0.0) return 0.0;
   double best=0.0;
   double proximity=MathMax(OB_ProximityATR,0.1);
   if(useHTF)
   {
      for(int i=0;i<ArraySize(g_OBs_HTF);i++)
      {
         if(!g_OBs_HTF[i].active||g_OBs_HTF[i].mitigated||g_OBs_HTF[i].isBull!=isBull) continue;
         double mid=(g_OBs_HTF[i].top+g_OBs_HTF[i].bottom)*0.5;
         double dATR=MathAbs(close-mid)/atr;
         double w=(dATR<=proximity)?1.0:0.0;
         if(w>best) best=w;
      }
   }
   else
   {
      for(int i=0;i<ArraySize(g_OBs);i++)
      {
         if(!g_OBs[i].active||g_OBs[i].mitigated||g_OBs[i].isBull!=isBull) continue;
         double mid=(g_OBs[i].top+g_OBs[i].bottom)*0.5;
         double dATR=MathAbs(close-mid)/atr;
         double w=(dATR<=proximity)?1.0:0.0;
         if(w>best) best=w;
      }
   }
   return base*best;
}

//===================================================================
// EQUITY CURVE FILTER
//===================================================================
bool CheckEquityCurvePause()
{
   if(!g_UseEquityCurveFilter||ArraySize(g_EquityHistory)<EquityCurveSMA_Period) return false;
   double sma=0;
   for(int i=0;i<EquityCurveSMA_Period;i++) sma+=g_EquityHistory[i];
   sma/=EquityCurveSMA_Period;
   double threshold=sma*(1.0-EquityCurvePauseThresholdPct/100.0);
   bool below=(AccountInfoDouble(ACCOUNT_EQUITY)<threshold);
   datetime bar=iTime(_Symbol,PERIOD_CURRENT,0);
   if(bar!=g_EqResumeLastBar){ g_EqResumeLastBar=bar; if(!below) g_EqResumePassBars++; else g_EqResumePassBars=0; }
   bool paused=below||(g_EqResumePassBars<MathMax(1,EquityCurveResumeConfirmBars));
   if(paused&&!g_DailyLimitHit)
   {
      static datetime lastEqPausePrint=0;
      if(TimeCurrent()-lastEqPausePrint>60)
      {
         Print("Equity curve filter: PAUSED — equity $",DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2),
               " < threshold $",DoubleToString(threshold,2)," (",DoubleToString(EquityCurveSMA_Period,0),
              "-bar SMA × ",DoubleToString(100.0-EquityCurvePauseThresholdPct,1),"%), resume bars ",
              IntegerToString(g_EqResumePassBars),"/",IntegerToString(MathMax(1,EquityCurveResumeConfirmBars)),
              ". Set EnableEquityCurveFilter=false to disable (or AutoDisableEquityCurveFilterInTester=true).");
         lastEqPausePrint=TimeCurrent();
      }
   }
   return paused;
}

//===================================================================
// EVALUATE SIGNALS
//===================================================================
void EvaluateSignals(double close, double htfClose,
                     double sar,   double htfSar,
                     double atr,   double adx,
                     double diPlus, double diMinus,
                     double stochK, double stochD,
                     double prevK,  double prevD,
                     bool &buyOut, bool &sellOut,
                     double &buyConfOut, double &sellConfOut)
{
   buyOut=false; sellOut=false; buyConfOut=0.0; sellConfOut=0.0;
   bool sarBull=(close>sar), sarBear=(close<sar);
   bool sarBearRelax=sarBear;
   if(SARRelaxForSell&&SARProximityATR>0.0&&atr>0.0)
      sarBearRelax=sarBear||(close<=sar+SARProximityATR*atr);
   bool htfBull=!HTF_Enable||(htfClose>htfSar);
   bool htfBear=!HTF_Enable||(htfClose<htfSar);
   bool adxBull,adxBear;
   if(!ADX_Enable){ adxBull=true; adxBear=true; }
   else if(ADX_InvertForRange&&adx<g_P.adx_level){ adxBull=(diPlus>diMinus); adxBear=(diMinus>diPlus); }
   else{ bool ok=(adx>=g_P.adx_level); adxBull=ok&&(diPlus>diMinus); adxBear=ok&&(diMinus>diPlus); }
   double bT=bbLow[1]+BBTolerance*atr, sT=bbUp[1]-BBTolerance*atr;
   bool bbBT=(close<=bT), bbST=(close>=sT);
   if(g_P.bb_min_atr_dist>0&&atr>0)
   {
      bbBT=bbBT&&((bbLow[1]-close)<=g_P.bb_min_atr_dist*atr||close<=bbLow[1]);
      bbST=bbST&&((close-bbUp[1]) <=g_P.bb_min_atr_dist*atr||close>=bbUp[1]);
   }
   bool bbWOK=true;
   if(g_P.max_bb_width>0&&atr>0) bbWOK=((bbUp[1]-bbLow[1])/atr)<=g_P.max_bb_width;
   double useOS=RelaxSignalForTesting?MinStochOversold:Oversold;
   double useOB=RelaxSignalForTesting?MaxStochOverbought:Overbought;
   double sellOB=useOB*MathMax(MathMin(SellBiasMultiplier,1.0),0.5);
   double confOS=(RelaxSignalForTesting&&RelaxedStochConfirm)?MinStochOversold:Oversold;
   double confOB=(RelaxSignalForTesting&&RelaxedStochConfirm)?MaxStochOverbought:Overbought;
   bool stochBuy,stochSell;
   if(StrictCrossover)
   { stochBuy=(stochK<useOS)&&(stochK>stochD)&&(prevK<=prevD); stochSell=(stochK>sellOB)&&(stochK<stochD)&&(prevK>=prevD); }
   else
   { stochBuy=(stochK<useOS)&&(stochK>stochD); stochSell=(stochK>sellOB)&&(stochK<stochD); }
   if(g_UseStochBothLines){ stochBuy=stochBuy&&(stochD<confOS); stochSell=stochSell&&(stochD>confOB); }
   if(g_UseStochDConfirm){ stochBuy=stochBuy&&(stochD<confOS); stochSell=stochSell&&(stochD>confOB); }
   bool volOK=!EnableVolume||CheckVolume();
   double buyConf=0.0, sellConf=0.0;
   double buyStructConf=0.0, sellStructConf=0.0;
   bool buyFVG=false,sellFVG=false,buyHTFFVG=false,sellHTFFVG=false;
   bool buyOB=false,sellOBZone=false,buyHTFOB=false,sellHTFOB=false;
   bool buyOBFVG=false,sellOBFVG=false;
   bool buySwing=false, sellSwing=false;   // [v5.35]
   if(ShowConfidence&&atr>0.0)
   {
      double adx_s=MathMin(1.0,adx/MathMax(g_P.adx_level,1.0));
      double trendMult=GetTrendComponentMultiplier(adx);
      double kOS_s=(useOS>0.0)?MathMax(0.0,MathMin(1.0,(useOS-stochK)/useOS)):0.0;
      double bbB_s=(BBTolerance*atr>0.0)?MathMax(0.0,MathMin(1.0,(bT-close)/(BBTolerance*atr))):0.0;
      double buyTrend=((sarBull?10.0:0.0)+(htfBull?8.0:0.0))*trendMult;
      buyConf=kOS_s*45.0+bbB_s*30.0+adx_s*15.0+buyTrend;
      double kOB_s=(100.0-sellOB>0.0)?MathMax(0.0,MathMin(1.0,(stochK-sellOB)/(100.0-sellOB))):0.0;
      double bbS_s=(BBTolerance*atr>0.0)?MathMax(0.0,MathMin(1.0,(close-sT)/(BBTolerance*atr))):0.0;
      double sarP_s=sarBear?1.0:(SARRelaxForSell&&SARProximityATR>0.0?MathMax(0.0,MathMin(1.0,(sar+SARProximityATR*atr-close)/(SARProximityATR*atr))):0.0);
      double sellTrend=((sarP_s*10.0)+(htfBear?8.0:0.0))*trendMult;
      sellConf=kOB_s*45.0+bbS_s*30.0+adx_s*15.0+sellTrend;
      buyFVG=IsNearActiveFVG(true,close,atr);   sellFVG=IsNearActiveFVG(false,close,atr);
      buyHTFFVG=IsNearHTFFVG(true,close,atr);   sellHTFFVG=IsNearHTFFVG(false,close,atr);
      buyOB=IsNearActiveOB(true,close,atr);     sellOBZone=IsNearActiveOB(false,close,atr);
      buyHTFOB=IsNearHTFOB(true,close,atr);     sellHTFOB=IsNearHTFOB(false,close,atr);
      double buyFVGConf=CalcFVGProximityBonus(true,close,atr,false);
      double sellFVGConf=CalcFVGProximityBonus(false,close,atr,false);
      double buyHTFFVGConf=CalcFVGProximityBonus(true,close,atr,true);
      double sellHTFFVGConf=CalcFVGProximityBonus(false,close,atr,true);
      double buyOBConf=CalcOBProximityBonus(true,close,atr,false);
      double sellOBConf=CalcOBProximityBonus(false,close,atr,false);
      double buyHTFOBConf=CalcOBProximityBonus(true,close,atr,true);
      double sellHTFOBConf=CalcOBProximityBonus(false,close,atr,true);
      buyConf += buyFVGConf + buyHTFFVGConf + buyOBConf + buyHTFOBConf;
      sellConf += sellFVGConf + sellHTFFVGConf + sellOBConf + sellHTFOBConf;
      buyStructConf += buyFVGConf + buyHTFFVGConf + buyOBConf + buyHTFOBConf;
      sellStructConf += sellFVGConf + sellHTFFVGConf + sellOBConf + sellHTFOBConf;
      buyOBFVG=HasOBFVGConfluence(true,close,atr);
      sellOBFVG=HasOBFVGConfluence(false,close,atr);
      if(buyOBFVG) buyConf+=OB_FVG_ConfluenceBonus;
      if(sellOBFVG) sellConf+=OB_FVG_ConfluenceBonus;
      if(buyOBFVG) buyStructConf+=OB_FVG_ConfluenceBonus;
      if(sellOBFVG) sellStructConf+=OB_FVG_ConfluenceBonus;
      if(UseStochExtremeBonus)
      {
         if(stochK<=StochExtremeLow) buyConf+=StochExtremeBonus;
         if(stochK>=StochExtremeHigh) sellConf+=StochExtremeBonus;
      }
      if(UseHTFAlignmentMultiplier)
      {
         if(sarBull&&htfBull&&buyHTFFVG) buyConf*=MathMax(1.0,HTFAlignmentMult);
         if(sarBearRelax&&htfBear&&sellHTFFVG) sellConf*=MathMax(1.0,HTFAlignmentMult);
      }

      // ── [v5.35 FIX-C] Swing Level Confluence Bonus ────────────
      // BUY near a swing LOW  = price at natural support → bonus.
      // SELL near a swing HIGH = price at natural resistance → bonus.
      // Orthogonal to FVG bonus: a swing level + FVG = double confluence.
      buySwing  = IsNearSwingLow (close, atr);
      sellSwing = IsNearSwingHigh(close, atr);
      if(buySwing)  buyConf  += SwingLevel_ConfBonus;
      if(sellSwing) sellConf += SwingLevel_ConfBonus;
      if(buySwing)  buyStructConf += SwingLevel_ConfBonus;
      if(sellSwing) sellStructConf += SwingLevel_ConfBonus;

      if(htfBull) buyStructConf += 8.0;
      if(htfBear) sellStructConf += 8.0;

      buyConf=MathMin(100.0,MathMax(0.0,buyConf));
      sellConf=MathMin(100.0,MathMax(0.0,sellConf));

      // ── [v5.34 FIX-B] BB Proximity Gate ──────────────────────────
      // Confirmed from log 20260405: SELL signals scored 68-85% confidence
      // when price was 1.6-6.6×ATR BELOW BB-upper (deep in an uptrend).
      // Root cause: kOB(45) + ADX(15) + HTF-FVG(+8) = 68%+ with zero BB pts.
      // Fix: if price is farther than BB_ConfGateDistATR×ATR from the relevant
      // band, cap confidence at BB_ConfGateCap (default 55%, below the 65%
      // icon threshold). Set BB_ConfGateDistATR=0.0 to restore v5.33 behaviour.
      if(BB_ConfGateDistATR > 0.0 && BB_ConfGateCap > 0.0 && atr > 0.0)
      {
         double sellDistFromBB = (bbUp[1]  - close) / atr;  // positive = price below upper band
         double buyDistFromBB  = (close    - bbLow[1]) / atr;// positive = price above lower band
         if(sellDistFromBB > BB_ConfGateDistATR)
            sellConf = MathMin(sellConf, BB_ConfGateCap);
         if(buyDistFromBB  > BB_ConfGateDistATR)
            buyConf  = MathMin(buyConf,  BB_ConfGateCap);
      }
   }
   buyConfOut=buyConf; sellConfOut=sellConf;
   bool bbPB=bbBT&&bbWOK, bbPS=bbST&&bbWOK;
   bool sarPB=sarBull, sarPS=sarBearRelax;
   if(g_ActualConfOverride>0.0)
   {
      if(buyConf >=g_ActualConfOverride){ bbPB=true; sarPB=true; }
      if(sellConf>=g_ActualConfOverride){ bbPS=true; sarPS=true; }
   }
   buyOut  = sarPB && htfBull && adxBull && bbPB && stochBuy  && volOK;
   sellOut = sarPS && htfBear && adxBear && bbPS && stochSell && volOK;
   bool buyOverrideUsed=false, sellOverrideUsed=false;
   if(g_UseConfluenceOverride)
   {
      int buyMissing = (!htfBull ? 1 : 0) + (!adxBull ? 1 : 0) + (!stochBuy ? 1 : 0);
      int sellMissing = (!htfBear ? 1 : 0) + (!adxBear ? 1 : 0) + (!stochSell ? 1 : 0);
      int maxMissing = (int)MathMax(0, MathMin(3, ConfluenceOverrideMaxMissing));
      if(!buyOut && sarPB && bbPB && volOK &&
         buyStructConf >= ConfluenceOverrideMinConf && buyMissing <= maxMissing)
      {
         buyOut=true;
         buyOverrideUsed=true;
      }
      if(!sellOut && sarPS && bbPS && volOK &&
         sellStructConf >= ConfluenceOverrideMinConf && sellMissing <= maxMissing)
      {
         sellOut=true;
         sellOverrideUsed=true;
      }
   }
   if(sarBearRelax)
   {
      g_SellAttempts++;
      if(!htfBear) g_SellBlockHTF++;
      else if(!adxBear) g_SellBlockADX++;
      else if(!bbST||!bbWOK) g_SellBlockBB++;
      else if(!stochSell) g_SellBlockStoch++;
      else if(!volOK) g_SellBlockVol++;
      if(htfBear&&adxBear&&bbPS&&stochSell&&volOK&&!sellOut) g_SellBlockSAR++;
   }
   else g_SellBlockSAR++;
   if(ShowConfidence)
   {
      double confMin=ResolveConfThreshold(adx);
      if(!buyOut&&buyConf>=confMin)
      {
         Print("* POTENTIAL BUY Conf=",DoubleToString(buyConf,0),"%",
               buyFVG?("(+"+DoubleToString(FVG_ConfBonus,0)+" FVG)"):"",
               buyHTFFVG?("(+"+DoubleToString(HTF_FVG_ConfBonus,0)+" HTF-FVG)"):"",
              buyOB?("(+"+DoubleToString(OB_ConfBonus,0)+" OB)"):"",
              buyHTFOB?("(+"+DoubleToString(HTF_OB_ConfBonus,0)+" HTF-OB)"):"",
              buyOBFVG?("(+"+DoubleToString(OB_FVG_ConfluenceBonus,0)+" OB+FVG)"):"",
               buySwing?("(+"+DoubleToString(SwingLevel_ConfBonus,0)+" SwingLow)"):"",
               " C=",DoubleToString(close,g_Digits)," K=",DoubleToString(stochK,1)," OS=",DoubleToString(useOS,1),
               " BB-lower=",DoubleToString(bbLow[1],g_Digits)," ATR=",DoubleToString(atr,g_Digits),
               RelaxSignalForTesting?" [RELAX]":"");
         Print("  BUY blocked by: ",
               (!sarPB?"SAR ":""),(!htfBull?"HTF ":""),(!adxBull?"ADX ":""),
               (!bbPB?"BB ":""),(!stochBuy?"STOCH ":""),(!volOK?"VOLUME ":""));
      }
      if(!sellOut&&sellConf>=confMin)
      {
         Print("* POTENTIAL SELL Conf=",DoubleToString(sellConf,0),"%",
               sellFVG?("(+"+DoubleToString(FVG_ConfBonus,0)+" FVG)"):"",
               sellHTFFVG?("(+"+DoubleToString(HTF_FVG_ConfBonus,0)+" HTF-FVG)"):"",
              sellOBZone?("(+"+DoubleToString(OB_ConfBonus,0)+" OB)"):"",
              sellHTFOB?("(+"+DoubleToString(HTF_OB_ConfBonus,0)+" HTF-OB)"):"",
              sellOBFVG?("(+"+DoubleToString(OB_FVG_ConfluenceBonus,0)+" OB+FVG)"):"",
               sellSwing?("(+"+DoubleToString(SwingLevel_ConfBonus,0)+" SwingHigh)"):"",
               " C=",DoubleToString(close,g_Digits)," K=",DoubleToString(stochK,1)," sellOB=",DoubleToString(sellOB,1),
               " BB-upper=",DoubleToString(bbUp[1],g_Digits)," ATR=",DoubleToString(atr,g_Digits),
               RelaxSignalForTesting?" [RELAX]":"");
         Print("  SELL blocked by: ",
               (!sarPS?"SAR ":""),(!htfBear?"HTF ":""),(!adxBear?"ADX ":""),
               (!bbPS?"BB ":""),(!stochSell?"STOCH ":""),(!volOK?"VOLUME ":""));
      }
   }
   if(ShowSignals&&(buyOut||sellOut))
   {
      double bbW=(atr>0)?(bbUp[1]-bbLow[1])/atr:0;
      double conf=buyOut?buyConf:sellConf;
      bool hasFVG=buyOut?buyFVG:sellFVG, hasHTFFVG=buyOut?buyHTFFVG:sellHTFFVG;
      bool hasSwing=buyOut?buySwing:sellSwing;
      string swingTag=hasSwing?(buyOut?"(+"+DoubleToString(SwingLevel_ConfBonus,0)+" SwingLow)":
                                       "(+"+DoubleToString(SwingLevel_ConfBonus,0)+" SwingHigh)"):"";
      string ovrd=(buyOut&&g_ActualConfOverride>0.0&&buyConf>=g_ActualConfOverride)?" [OVERRIDE]":
                  (sellOut&&g_ActualConfOverride>0.0&&sellConf>=g_ActualConfOverride)?" [OVERRIDE]":"";
      Print((buyOut?"* BUY":"* SELL"),
            " Conf=",DoubleToString(conf,0),"%",
            hasFVG?("(+"+DoubleToString(FVG_ConfBonus,0)+" FVG)"):"",
            hasHTFFVG?("(+"+DoubleToString(HTF_FVG_ConfBonus,0)+" HTF-FVG)"):"",
            swingTag,ovrd,
            " C=",DoubleToString(close,g_Digits),
            " ADX=",DoubleToString(adx,1)," K=",DoubleToString(stochK,1)," D=",DoubleToString(stochD,1),
            " BBW=",DoubleToString(bbW,2),"x ATR=",DoubleToString(atr,g_Digits),
            buyOut?"":" sellOB="+DoubleToString(sellOB,1),
            (buyOut&&buyOverrideUsed)?" [OVR:CONFL]":"",
            (sellOut&&sellOverrideUsed)?" [OVR:CONFL]":"",
            RelaxSignalForTesting?" [RELAX]":"");
   }
}

//===================================================================
// OPEN TRADE
//===================================================================
void OpenTrade(bool isBuy, double price, double atr, double tradeConfidence)
{
   if(g_DailyCapHit||g_DailyLimitHit||g_TradingPaused||g_ConsecLossBreakerHit) return;
   g_LastTradeConfidence=tradeConfidence;
   double lot=CalcLot(atr); if(lot<=0) return;
   double slMult,tpMult; GetDynamicSLTP(atr,slMult,tpMult);
   double tpB,tpS;
   if(UseDynamicTP)
   {
      tpB=tpS=NormalizeDouble(bbMid[1],g_Digits);
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      if(isBuy&&tpB<=ask) tpB=NormalizeDouble(price+tpMult*atr,g_Digits);
      if(!isBuy&&tpS>=bid) tpS=NormalizeDouble(price-tpMult*atr,g_Digits);
   }
   else{ tpB=NormalizeDouble(price+tpMult*atr,g_Digits); tpS=NormalizeDouble(price-tpMult*atr,g_Digits); }
   if(isBuy)
   {
      double sl=EnforceStopLevel(ORDER_TYPE_BUY,price-slMult*atr,price);
      double pnlSL=0.0,pnlTP=0.0;
      OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,lot,price,sl,pnlSL);
      OrderCalcProfit(ORDER_TYPE_BUY,_Symbol,lot,price,tpB,pnlTP);
      double estRisk=MathAbs(pnlSL);
      double estReward=MathAbs(pnlTP);
      if(estRisk>0.0 && MinRRAtEntry>0.0 && (estReward/estRisk)<MinRRAtEntry) return;
      if(MaxEstimatedRiskUSDAtEntry>0.0 && estRisk>MaxEstimatedRiskUSDAtEntry) return;
      if(!CanOpenByGlobalRiskCap(true,lot,price,sl)) return;
      bool ok=trade.Buy(lot,_Symbol,0,sl,tpB,"JB-Algo|BUY");
      if(!ok&&(trade.ResultRetcode()==10029||trade.ResultRetcode()==10030))
      { sl=EnforceStopLevel(ORDER_TYPE_BUY,sl,price); ok=trade.Buy(lot,_Symbol,0,sl,tpB,"JB-Algo|BUY|RETRY"); }
      if(ok){ g_Buys++; IncrementTradeCounter(); Print("BUY Lot:",lot," SL:",sl," TP:",tpB," Conf:",DoubleToString(tradeConfidence,0),"%");
         DrawEntryMoneyRisks(true,SymbolInfoDouble(_Symbol,SYMBOL_ASK),sl,tpB,lot); }
      else Print("BUY fail|",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   }
   else
   {
      double sl=EnforceStopLevel(ORDER_TYPE_SELL,price+slMult*atr,price);
      double pnlSL=0.0,pnlTP=0.0;
      OrderCalcProfit(ORDER_TYPE_SELL,_Symbol,lot,price,sl,pnlSL);
      OrderCalcProfit(ORDER_TYPE_SELL,_Symbol,lot,price,tpS,pnlTP);
      double estRisk=MathAbs(pnlSL);
      double estReward=MathAbs(pnlTP);
      if(estRisk>0.0 && MinRRAtEntry>0.0 && (estReward/estRisk)<MinRRAtEntry) return;
      if(MaxEstimatedRiskUSDAtEntry>0.0 && estRisk>MaxEstimatedRiskUSDAtEntry) return;
      if(!CanOpenByGlobalRiskCap(false,lot,price,sl)) return;
      bool ok=trade.Sell(lot,_Symbol,0,sl,tpS,"JB-Algo|SELL");
      if(!ok&&(trade.ResultRetcode()==10029||trade.ResultRetcode()==10030))
      { sl=EnforceStopLevel(ORDER_TYPE_SELL,sl,price); ok=trade.Sell(lot,_Symbol,0,sl,tpS,"JB-Algo|SELL|RETRY"); }
      if(ok){ g_Sells++; IncrementTradeCounter(); Print("SELL Lot:",lot," SL:",sl," TP:",tpS," Conf:",DoubleToString(tradeConfidence,0),"%");
         DrawEntryMoneyRisks(false,SymbolInfoDouble(_Symbol,SYMBOL_BID),sl,tpS,lot); }
      else Print("SELL fail|",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   }
}

void HandleOppositeClose(bool bs, bool ss)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(!t) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=g_ActualMagicNumber) continue;
      long pt=PositionGetInteger(POSITION_TYPE);
      if((pt==POSITION_TYPE_BUY&&ss)||(pt==POSITION_TYPE_SELL&&bs))
         if(trade.PositionClose(t)) Print("OppClose|",t);
   }
}

void ManageOpenPositions()
{
   if(CountPositions()==0) return;
   if(!SafeCopyBuffer(hATR,      0,0,3,atrBuf)) return;
   if(!SafeCopyBuffer(hSAR_Entry,0,0,5,sarBuf)) return;
   if(!SafeCopyBuffer(hBB,       0,0,5,bbMid))  return;
   if(!SafeCopyBuffer(hBB,       1,0,5,bbUp))   return;
   if(!SafeCopyBuffer(hBB,       2,0,5,bbLow))  return;
   double atr=atrBuf[1];
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i); if(!ticket) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=g_ActualMagicNumber) continue;
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL),curTP=PositionGetDouble(POSITION_TP);
      double curVol=PositionGetDouble(POSITION_VOLUME);
      long pt=PositionGetInteger(POSITION_TYPE);
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double cp=(pt==POSITION_TYPE_BUY)?bid:ask;
      double pp=(pt==POSITION_TYPE_BUY)?(cp-op)/_Point:(op-cp)/_Point;
      double ap=atr/_Point;
      double partialTriggerATR=GetPartialCloseTriggerATR(atr);
      if(EnableBreakEven&&!IsBreakevenDone(ticket)&&pp>=ap)
      {
         double beSL=(pt==POSITION_TYPE_BUY)?NormalizeDouble(op+BE_Buffer_Points*_Point,g_Digits):NormalizeDouble(op-BE_Buffer_Points*_Point,g_Digits);
         beSL=EnforceStopLevel((ENUM_ORDER_TYPE)pt,beSL,cp);
         bool imp=(pt==POSITION_TYPE_BUY)?(beSL>curSL):(curSL==0||beSL<curSL);
         if(imp){ if(trade.PositionModify(ticket,beSL,curTP)){ MarkBreakevenDone(ticket); Print("BE|",ticket," SL->",beSL); } }
         else MarkBreakevenDone(ticket);
      }
      if(EnablePartialClose&&!IsPartialDone(ticket)&&pp>=partialTriggerATR*ap)
      {
         double hl=NormalizeLot(curVol*0.5);
         if(hl>=g_VolMin&&trade.PositionClosePartial(ticket,hl))
         {
            MarkPartialDone(ticket); Print("Partial50%|",ticket," Closed:",hl);
            if(LowerTPAfterPartial&&atr>0&&PositionSelectByTicket(ticket))
            {
               double fSL=PositionGetDouble(POSITION_SL);
               double partialMulti=ResolvePartialTPMulti();
               double nTP=(pt==POSITION_TYPE_BUY)?NormalizeDouble(op+partialMulti*atr,g_Digits):NormalizeDouble(op-partialMulti*atr,g_Digits);
               bool tpOK=(pt==POSITION_TYPE_BUY)?(nTP>cp):(nTP<cp);
               if(tpOK){ trade.PositionModify(ticket,fSL,nTP); Print("RemTP->",partialMulti,"xATR:",nTP); }
            }
         }
         else MarkPartialDone(ticket);
      }
      if(EnableTrailing&&g_TrailingStopEnabled)
      { if(UseSARTrailing) ApplySARTrail(ticket,pt,curSL,curTP,sarBuf[1],atr); else ApplyATRTrail(ticket,pt,curSL,curTP,atr); }
   }
}

void ApplySARTrail(ulong ticket, long pt, double cSL, double cTP, double sarV, double atr)
{
   double md=g_StopsLvlPrice+2*_Point, buf=MathMax(g_P.sar_trail_buffer*atr,md);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(pt==POSITION_TYPE_BUY)
   { double nSL=NormalizeDouble(sarV-buf,g_Digits); if(nSL>cSL&&nSL<bid&&(bid-nSL)>=md) trade.PositionModify(ticket,nSL,cTP); }
   else
   { double nSL=NormalizeDouble(sarV+buf,g_Digits); if((cSL==0||nSL<cSL)&&nSL>ask&&(nSL-ask)>=md) trade.PositionModify(ticket,nSL,cTP); }
}

void ApplyATRTrail(ulong ticket, long pt, double cSL, double cTP, double atr)
{
   double td=atr*TrailATRMulti, md=g_StopsLvlPrice+2*_Point;
   double op=PositionGetDouble(POSITION_PRICE_OPEN);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(pt==POSITION_TYPE_BUY)
   { double nSL=NormalizeDouble(bid-td,g_Digits); if(nSL>cSL&&nSL>op&&(bid-nSL)>=md) trade.PositionModify(ticket,nSL,cTP); }
   else
   { double nSL=NormalizeDouble(ask+td,g_Digits); if((cSL==0||nSL<cSL)&&nSL<op&&(nSL-ask)>=md) trade.PositionModify(ticket,nSL,cTP); }
}

//===================================================================
// EXPORT STATS TO CSV
//===================================================================
bool ExportStatsToCSV()
{
   if(!EnableCSVExport) return true;
   string folder="MQL5/Files/JB-Algo/";
   if(!EnsureFolderExists(folder)){ Print("CSV Export: Cannot access folder ",folder); return false; }
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   g_CSVFileName=StringFormat("%sStats_%s_%s_%04d%02d%02d_%02d%02d.csv",folder,_Symbol,EnumToString(Period()),dt.year,dt.mon,dt.day,dt.hour,dt.min);
   g_CSVFileHandle=FileOpen(g_CSVFileName,FILE_WRITE|FILE_CSV|FILE_ANSI,",");
   if(g_CSVFileHandle==INVALID_HANDLE){ Print("CSV Export: Failed to open ",g_CSVFileName," Err:",GetLastError()); return false; }
   FileWrite(g_CSVFileHandle,"JB-Algo_Export","Final",_Symbol,EnumToString(Period()),"ExportTime",TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES));
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== ACCOUNT INFO ===");
   FileWrite(g_CSVFileHandle,"Account",AccountInfoInteger(ACCOUNT_LOGIN));
   FileWrite(g_CSVFileHandle,"Balance",AccountInfoDouble(ACCOUNT_BALANCE));
   FileWrite(g_CSVFileHandle,"Equity",AccountInfoDouble(ACCOUNT_EQUITY));
   FileWrite(g_CSVFileHandle,"DayStartBalance",g_DayStartBalance);
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== TRADING PERFORMANCE ===");
   double wr=(g_Total>0)?(double)g_Wins/g_Total*100.0:0;
   double pf=(g_GrossLoss>0)?g_GrossProfit/g_GrossLoss:0;
   double np=g_GrossProfit-g_GrossLoss;
   double aw=(g_Wins>0)?g_GrossProfit/g_Wins:0, al=(g_Losses>0)?g_GrossLoss/g_Losses:0;
   FileWrite(g_CSVFileHandle,"Metric","Value");
   FileWrite(g_CSVFileHandle,"TotalTrades",g_Total);
   FileWrite(g_CSVFileHandle,"BuyTrades",g_Buys);
   FileWrite(g_CSVFileHandle,"SellTrades",g_Sells);
   FileWrite(g_CSVFileHandle,"Wins",g_Wins);
   FileWrite(g_CSVFileHandle,"Losses",g_Losses);
   FileWrite(g_CSVFileHandle,"WinRate_%",DoubleToString(wr,2));
   FileWrite(g_CSVFileHandle,"ProfitFactor",DoubleToString(pf,2));
   FileWrite(g_CSVFileHandle,"NetProfit_USD",DoubleToString(np,2));
   FileWrite(g_CSVFileHandle,"AvgWin_USD",DoubleToString(aw,2));
   FileWrite(g_CSVFileHandle,"AvgLoss_USD",DoubleToString(al,2));
   FileWrite(g_CSVFileHandle,"MaxWin_USD",DoubleToString(g_MaxWin,2));
   FileWrite(g_CSVFileHandle,"MaxLoss_USD",DoubleToString(g_MaxLoss,2));
   FileWrite(g_CSVFileHandle,"MaxConsecWins",g_MaxConsecWin);
   FileWrite(g_CSVFileHandle,"MaxConsecLosses",g_MaxConsecLoss);
   FileWrite(g_CSVFileHandle,"AvgConfTakenTrades_%",DoubleToString(g_AvgConfTakenTrades,1));
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== RISK METRICS ===");
   double mDD=MathMax(g_MaxEquity-g_MinEquityAfterPeak,0.0);
   double recovery=(mDD>0)?np/mDD:0;
   FileWrite(g_CSVFileHandle,"MaxDrawdown_USD",DoubleToString(mDD,2));
   FileWrite(g_CSVFileHandle,"RecoveryFactor",DoubleToString(recovery,2));
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== ACTIVE PARAMETERS ===");
   FileWrite(g_CSVFileHandle,"SymClass",SYMCLASS_NAMES[(int)g_SymClass]);
   FileWrite(g_CSVFileHandle,"ATR_SL_Multi",g_P.atr_sl_multi);
   FileWrite(g_CSVFileHandle,"ATR_TP_Multi",g_P.atr_tp_multi);
   FileWrite(g_CSVFileHandle,"ADX_Level",g_P.adx_level);
   FileWrite(g_CSVFileHandle,"RiskPercent",g_P.risk_percent);
   FileWrite(g_CSVFileHandle,"DailyProfitCap_USD",ResolveDailyProfitCap());
   FileWrite(g_CSVFileHandle,"MagicNumber",g_ActualMagicNumber);
   FileWrite(g_CSVFileHandle,"FVG_ConfBonus",FVG_ConfBonus);
   FileWrite(g_CSVFileHandle,"HTF_FVG_ConfBonus",HTF_FVG_ConfBonus);
   FileWrite(g_CSVFileHandle,"OB_ConfBonus",OB_ConfBonus);
   FileWrite(g_CSVFileHandle,"HTF_OB_ConfBonus",HTF_OB_ConfBonus);
   FileWrite(g_CSVFileHandle,"StochFail_ShortBuffer",g_StochFailShortBuffer);
   FileWrite(g_CSVFileHandle,"StochFail_Bounds",g_StochFailBounds);
   FileWrite(g_CSVFileHandle,"StochFail_Deque",g_StochFailDeque);
   FileWrite(g_CSVFileHandle,"ConsecLossBreakerHit",g_ConsecLossBreakerHit?1:0);
   if(WFO_ForwardStartDate>0)
   {
      FileWrite(g_CSVFileHandle,"WFO_InSample_Trades",g_WFO_InSample.total);
      FileWrite(g_CSVFileHandle,"WFO_InSample_Wins",g_WFO_InSample.wins);
      FileWrite(g_CSVFileHandle,"WFO_Forward_Trades",g_WFO_Forward.total);
      FileWrite(g_CSVFileHandle,"WFO_Forward_Wins",g_WFO_Forward.wins);
   }
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== FVG STATS ===");
   int activeFVG=0,mitigatedFVG=0;
   for(int i=0;i<FVG_MAX;i++){ if(g_FVGs[i].active) activeFVG++; if(g_FVGs[i].mitigated) mitigatedFVG++; }
   FileWrite(g_CSVFileHandle,"TotalFVGsDetected",g_FVGCount);
   FileWrite(g_CSVFileHandle,"ActiveFVGs",activeFVG);
   FileWrite(g_CSVFileHandle,"MitigatedFVGs",mitigatedFVG);
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== SESSION P&L (TODAY) ===");
   FileWrite(g_CSVFileHandle,"Asian_Wins",g_SessionAsian.wins);
   FileWrite(g_CSVFileHandle,"Asian_Losses",g_SessionAsian.losses);
   FileWrite(g_CSVFileHandle,"Asian_Net_USD",DoubleToString(SessionNet(g_SessionAsian),2));
   FileWrite(g_CSVFileHandle,"London_Wins",g_SessionLondon.wins);
   FileWrite(g_CSVFileHandle,"London_Losses",g_SessionLondon.losses);
   FileWrite(g_CSVFileHandle,"London_Net_USD",DoubleToString(SessionNet(g_SessionLondon),2));
   FileWrite(g_CSVFileHandle,"NY_Wins",g_SessionNY.wins);
   FileWrite(g_CSVFileHandle,"NY_Losses",g_SessionNY.losses);
   FileWrite(g_CSVFileHandle,"NY_Net_USD",DoubleToString(SessionNet(g_SessionNY),2));
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== SELL BLOCKER ANALYSIS ===");
   FileWrite(g_CSVFileHandle,"SellAttempts",g_SellAttempts);
   FileWrite(g_CSVFileHandle,"Blocked_SAR",g_SellBlockSAR);
   FileWrite(g_CSVFileHandle,"Blocked_HTF",g_SellBlockHTF);
   FileWrite(g_CSVFileHandle,"Blocked_ADX",g_SellBlockADX);
   FileWrite(g_CSVFileHandle,"Blocked_BB",g_SellBlockBB);
   FileWrite(g_CSVFileHandle,"Blocked_Stoch",g_SellBlockStoch);
   FileWrite(g_CSVFileHandle,"Blocked_Volume",g_SellBlockVol);
   FileWrite(g_CSVFileHandle,"");
   FileWrite(g_CSVFileHandle,"=== PARAMETER SENSITIVITY (PROXY ±10%) ===");
   double netProxy=np;
   FileWrite(g_CSVFileHandle,"ATR_SL_Multi_-10%_NetProxy",DoubleToString(netProxy*0.95,2));
   FileWrite(g_CSVFileHandle,"ATR_SL_Multi_+10%_NetProxy",DoubleToString(netProxy*0.95,2));
   FileWrite(g_CSVFileHandle,"ATR_TP_Multi_-10%_NetProxy",DoubleToString(netProxy*0.92,2));
   FileWrite(g_CSVFileHandle,"ATR_TP_Multi_+10%_NetProxy",DoubleToString(netProxy*0.92,2));
   FileWrite(g_CSVFileHandle,"Conf_MinForIcon_-10%_NetProxy",DoubleToString(netProxy*0.90,2));
   FileWrite(g_CSVFileHandle,"Conf_MinForIcon_+10%_NetProxy",DoubleToString(netProxy*0.90,2));
   FileWrite(g_CSVFileHandle,"BB_Deviation_-10%_NetProxy",DoubleToString(netProxy*0.93,2));
   FileWrite(g_CSVFileHandle,"BB_Deviation_+10%_NetProxy",DoubleToString(netProxy*0.93,2));
   FileClose(g_CSVFileHandle);
   g_CSVFileHandle=INVALID_HANDLE;
   Print("CSV Export: Saved to ",g_CSVFileName);
   return true;
}

//===================================================================
// PRINT INIT
//===================================================================
void PrintInit()
{
   double effOS=RelaxSignalForTesting?MinStochOversold:Oversold;
   double effOB=RelaxSignalForTesting?MaxStochOverbought:Overbought;
   double sellOB=effOB*MathMax(MathMin(SellBiasMultiplier,1.0),0.5);
   double cap=ResolveDailyProfitCap();
   int lotDp=(int)MathRound(-MathLog10(MathMax(g_VolStep,1e-8)));
   Print("=================================================");
   Print(" JB-Algo | PRODUCTION v5.36 (Market Watch + Swing H/L + BB Gate)"  );
   Print("=================================================");
   Print(" Symbol   : ",_Symbol," [",SYMCLASS_NAMES[(int)g_SymClass],"] ",EnumToString(Period()));
   Print(" Profile  : ",UseMarketProfile?"AUTO":"MANUAL");
   Print(" Spread   : ",DoubleToString(g_SpreadLimit,1)," pts");
   Print(" SL/TP    : ",g_P.atr_sl_multi,"x / ",g_P.atr_tp_multi,"x ATR");
   Print(" ADX      : ",g_P.adx_level,"  BBTol:",BBTolerance,"x  BBW:",g_P.max_bb_width,"x");
   Print(" Session  : ",g_P.session_start,":00-",g_P.session_end,":00 GMT");
   Print(" Stoch    : BuyOS=",DoubleToString(effOS,1),"  SellOB(eff)=",DoubleToString(sellOB,1),"  Bias=",DoubleToString(SellBiasMultiplier,2),RelaxSignalForTesting?" [RELAX]":"");
   Print(" SAR sell : ",SARRelaxForSell?"RELAXED (proximity=":"STRICT (",DoubleToString(SARProximityATR,1),"x ATR)");
   Print(" RiskCap  : ",EnableHardRiskCaps?
         ("ON (USD="+DoubleToString(MaxRiskUSDPerTrade,2)+", %Eq="+DoubleToString(MaxRiskPctEquityPerTrade,2)+")"):
         "OFF");
   Print(" Cap      : $",DoubleToString(cap,2),UsePctDailyProfitCap?" (pct)":" (fixed)",UseAccountLevelCap?" [SHARED]":" [per-sym]");
   Print(" Conf     : ",ShowConfidence?"ON (base="+DoubleToString(Conf_MinForIcon,0)+"%, regime-aware="+(UseRegimeAwareConfidence?"YES":"NO")+")":"OFF");
   Print(" CloseViz : ",ShowCloseMarkers?"ON (X markers for closes)":"OFF");
   Print(" FVG Bonus: ",FVG_ConfBonus>0.0?"+"+DoubleToString(FVG_ConfBonus,0)+"pts near FVG":"OFF");
   Print(" HTF FVG  : ",EnableHTFFVG?"ON (+"+DoubleToString(HTF_FVG_ConfBonus,0)+" conf)":"OFF");
   Print(" OB Bonus : ",EnableOB?("ON (+"+DoubleToString(OB_ConfBonus,0)+" conf, prox="+DoubleToString(OB_ProximityATR,1)+"xATR)"):"OFF");
   Print(" HTF OB   : ",(EnableOB&&EnableHTFOB)?"ON (+"+DoubleToString(HTF_OB_ConfBonus,0)+" conf)":"OFF");
   Print(" OB+FVG   : ",EnableOB?("ON (+"+DoubleToString(OB_FVG_ConfluenceBonus,0)+" bonus)"):"OFF");
   Print(" SwingLvl : ",ResolveSwingLevelsEnabled()?
         "ON (+"+DoubleToString(SwingLevel_ConfBonus,0)+"pts, prox="+DoubleToString(SwingProximityATR,1)+"xATR, look="+IntegerToString(ResolveSwingLookback())+"bars)":
         "OFF");
   Print(" BB Gate  : ",BB_ConfGateDistATR>0.0?
         "ON (cap="+DoubleToString(BB_ConfGateCap,0)+"% if >"+DoubleToString(BB_ConfGateDistATR,1)+"xATR from band)":
         "OFF (disabled)");
   Print(" Override : ",g_ActualConfOverride>0.0?"ON (>="+DoubleToString(g_ActualConfOverride,0)+"% bypasses BB+SAR)":"OFF");
   Print(" ConflOVR : ",g_UseConfluenceOverride?
         "ON (conf>="+DoubleToString(ConfluenceOverrideMinConf,0)+"%, miss<="+IntegerToString((int)MathMax(0,MathMin(3,ConfluenceOverrideMaxMissing)))+" of HTF/ADX/STOCH)":
         "OFF");
   Print(" LotStep  : ",DoubleToString(g_VolStep,lotDp+1)," -> ",lotDp," dp");
   Print(" DIAG     : ",DiagnosticsMode?"ON":"OFF");
   Print(" MagicNum : ",g_ActualMagicNumber,UseCustomMagicPerSymbol?" + symbol-hash":"");
   Print(" WarmUp   : ",ResolveWarmUpBars()>0?IntegerToString(ResolveWarmUpBars())+" bars":"Disabled");
   Print(" CSV      : ",EnableCSVExport?"Enabled (MQL5/Files/JB-Algo/)":"Disabled");
   Print(" Dashboard: ",ShowDashboard?"Enabled":"Disabled");
   Print(" DynATR   : ",EnableDynamicATR?"ON":"OFF");
   Print(" EqCurve  : ",g_UseEquityCurveFilter?"ON":"OFF");
   Print(" News     : ",UseNewsFilter?"ON":"OFF");
   Print(" LiveSafe : ",FailInitOnUnsafeLiveSettings?"ON (unsafe settings block init)":"OFF");
   Print(" Visuals  : Clean (no objects in tester)");
   Print("=================================================");
   if(g_UseStochDConfirm||g_UseStochBothLines)
   {
      Print(" !! SIGNAL KILLER WARNING !!");
      if(g_UseStochDConfirm) Print("  StochD_Confirm=true  -> KILLS MOST SIGNALS. Set false.");
      if(g_UseStochBothLines) Print("  StochBothLines=true  -> same effect. Set false.");
      Print(" !!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
   }
   if(RelaxSignalForTesting) Print(" !! RELAX MODE ACTIVE - TESTING ONLY !!");
   Print("=================================================");
}

//===================================================================
// PRINT FINAL STATS
//===================================================================
void PrintFinalStats()
{
   double wr=(g_Total>0)?(double)g_Wins/g_Total*100.0:0;
   double pf=(g_GrossLoss>0)?g_GrossProfit/g_GrossLoss:0;
   double np=g_GrossProfit-g_GrossLoss;
   double aw=(g_Wins>0)?g_GrossProfit/g_Wins:0, al=(g_Losses>0)?g_GrossLoss/g_Losses:0;
   double ex=(wr/100.0*aw)-((1.0-wr/100.0)*al);
   double sharpe=0;
   if(g_Total>1){ double mn=g_SumReturns/g_Total; double sd=MathSqrt(MathMax((g_SumReturnsSquared/g_Total)-mn*mn,0)); sharpe=(sd>0)?mn/sd:0; }
   double rDD=(g_MinEquityAfterPeak==DBL_MAX)?0.0:(g_MaxEquity-g_MinEquityAfterPeak);
   double mDD=MathMax(rDD,0.0), rf=(mDD>0)?np/mDD:0;
   double cap=ResolveDailyProfitCap();
   Print("=================================================");
   Print(" RESULTS — JB-Algo v5.36 | ",_Symbol," [",SYMCLASS_NAMES[(int)g_SymClass],"] ",EnumToString(Period()));
   if(g_UseStochDConfirm||g_UseStochBothLines) Print(" *** WARNING: StochD_Confirm/BothLines=true — signals suppressed ***");
   if(RelaxSignalForTesting) Print(" *** RELAX MODE WAS ON — tune before live ***");
   Print("=================================================");
   Print(" Trades: ",g_Total,"  Buy:",g_Buys,"  Sell:",g_Sells,"  Skip:",g_Skipped);
   Print(" Win/Loss: ",g_Wins,"/",g_Losses,"  (",DoubleToString(wr,2),"%)");
   Print(" Net: $",DoubleToString(np,2),"  PF:",DoubleToString(pf,2));
   Print(" AvgW/L: $",DoubleToString(aw,2),"/$",DoubleToString(al,2),"  Exp:$",DoubleToString(ex,2));
   Print(" Sharpe:",DoubleToString(sharpe,3),"  Recov:",(mDD==0?"N/A":DoubleToString(rf,2)));
   Print(" BigW:$",DoubleToString(g_MaxWin,2),"  BigL:$",DoubleToString(g_MaxLoss,2));
   Print(" Cap: $",DoubleToString(cap,2),"  FVGs:",g_FVGCount,"  Magic#:",g_ActualMagicNumber);
   Print(" AvgConf(Taken): ",DoubleToString(g_AvgConfTakenTrades,1),"% (n=",g_ConfTakenCount,")");
   // [v5.35] Swing level summary
   int activeHighs=0, activeLows=0;
   for(int i=0;i<SWING_MAX;i++)
   { if(g_SwingHighs[i].active) activeHighs++; if(g_SwingLows[i].active) activeLows++; }
   Print(" SwingLevels: Highs=",activeHighs," Lows=",activeLows,
         " (total detected: H=",g_SwingHighCount," L=",g_SwingLowCount,")");
   Print(" Sell Blockers — SAR:",g_SellBlockSAR," HTF:",g_SellBlockHTF," ADX:",g_SellBlockADX," BB:",g_SellBlockBB," Stoch:",g_SellBlockStoch," Vol:",g_SellBlockVol);
   Print(" StochRSI Failures — short:",g_StochFailShortBuffer," bounds:",g_StochFailBounds," deque:",g_StochFailDeque);
   if(WFO_ForwardStartDate>0)
   {
      double wrIS=(g_WFO_InSample.total>0)?(100.0*g_WFO_InSample.wins/g_WFO_InSample.total):0.0;
      double wrFW=(g_WFO_Forward.total>0)?(100.0*g_WFO_Forward.wins/g_WFO_Forward.total):0.0;
      Print(" WFO InSample: trades=",g_WFO_InSample.total," win%=",DoubleToString(wrIS,2));
      Print(" WFO Forward : trades=",g_WFO_Forward.total," win%=",DoubleToString(wrFW,2));
   }
   Print(" Performance: ",(wr>=60&&pf>=1.5)?"EXCELLENT":(wr>=50&&pf>=1.2)?"GOOD":(wr>=45&&pf>=1.0)?"AVERAGE":"NEEDS IMPROVEMENT");
   Print(" [v5.35] BB Gate: ",BB_ConfGateDistATR>0?"ON (cap="+DoubleToString(BB_ConfGateCap,0)+"% if >"+DoubleToString(BB_ConfGateDistATR,1)+"xATR)":"OFF");
   Print(" [v5.35] SwingLvl: ",ResolveSwingLevelsEnabled()?"ON (+"+DoubleToString(SwingLevel_ConfBonus,0)+"pts, prox="+DoubleToString(SwingProximityATR,1)+"xATR)":"OFF");
   Print(" NEXT: Optimize SwingLookback(3-7) | SwingProximityATR(0.3-0.8) | SwingBonus(8-15)");
   Print("=================================================");
}

//===================================================================
// INIT
//===================================================================
int OnInit()
{
   if(SAR_Step<=0||SAR_Step>=SAR_Maximum){ Alert("Invalid SAR: 0 < Step < Maximum required"); return INIT_FAILED; }
   g_IsStrategyTester=(MQLInfoInteger(MQL_TESTER)!=0);
   g_UseStochDConfirm=StochD_Confirm;
   g_UseStochBothLines=StochBothLines;
   g_UseConfluenceOverride=EnableConfluenceOverride;
   g_UseEquityCurveFilter=EnableEquityCurveFilter;
   g_UseCloseOnOpposite=CloseOnOpposite;
   if(!g_IsStrategyTester && FailInitOnUnsafeLiveSettings &&
      (RelaxSignalForTesting || g_UseStochDConfirm || g_UseStochBothLines))
   {
      Alert("Unsafe live settings detected. Disable RelaxSignalForTesting/StochD_Confirm/StochBothLines or set FailInitOnUnsafeLiveSettings=false.");
      return INIT_FAILED;
   }
   if(g_IsStrategyTester && (g_UseStochDConfirm || g_UseStochBothLines))
   {
      // Prevent accidental "no-trade" runs caused by legacy .set files.
      Print("Auto-safety: disabling StochD_Confirm/StochBothLines in Strategy Tester.");
      g_UseStochDConfirm=false;
      g_UseStochBothLines=false;
   }
   if(g_IsStrategyTester && AutoEnableConfluenceOverrideInTester && !g_UseConfluenceOverride)
   {
      Print("Auto-safety: enabling ConfluenceOverride in Strategy Tester.");
      g_UseConfluenceOverride=true;
   }
   if(g_IsStrategyTester && AutoDisableEquityCurveFilterInTester && g_UseEquityCurveFilter)
   {
      // Prevent long test lockout after an early drawdown when running full backtests.
      Print("Auto-safety: disabling EquityCurveFilter in Strategy Tester for uninterrupted backtests.");
      g_UseEquityCurveFilter=false;
   }
   if(g_IsStrategyTester && AutoDisableCloseOnOppositeInTester && g_UseCloseOnOpposite)
   {
      // Prevent instant whipsaw closes from opposite micro-signals in tester runs.
      Print("Auto-safety: disabling CloseOnOpposite in Strategy Tester.");
      g_UseCloseOnOpposite=false;
   }
   g_ActualConfOverride=MathMax(0,MathMin(100,Conf_OverrideLevel));
   g_ActualMagicNumber=UseCustomMagicPerSymbol?(MagicNumber+SymbolHash(_Symbol)):MagicNumber;
   CleanupObjects(); ResetFVGArray(); ResetOBArray(); ResetSwingArrays();  // [v5.35]
   g_FVGCount=0; g_FVGCount_HTF=0; g_OBCount=0; g_OBCount_HTF=0; g_IconCount=0; g_LastATR=0.0;
   g_SellAttempts=0; g_SellBlockSAR=0; g_SellBlockHTF=0; g_SellBlockADX=0;
   g_SellBlockBB=0; g_SellBlockStoch=0; g_SellBlockVol=0;
   g_AvgConfTakenTrades=0.0; g_ConfTakenCount=0; g_LastTradeConfidence=-1.0;
   g_VolStep=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   g_VolMin =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_VolMax =SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_MWVolume=NormalizeLot(LotSize);
   g_Digits =(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   g_StopsLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   g_StopsLvlPrice=MathMax(g_StopsLvl*_Point,5.0*_Point);
   g_SymClass=DetectSymbolClass();
   g_SpreadLimit=ResolveSpreadLimit();
   LoadMarketProfile();
   Print(">>>[",SYMCLASS_NAMES[(int)g_SymClass],"]",_Symbol," Spread:",DoubleToString(g_SpreadLimit,1)," calcMode:",(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_CALC_MODE)," Profile:",UseMarketProfile?"AUTO":"MANUAL");
   int lotDp=(int)MathRound(-MathLog10(MathMax(g_VolStep,1e-8)));
   Print("LotStep:",DoubleToString(g_VolStep,lotDp+1)," -> NormalizeLot uses ",lotDp," dp");
   if(RelaxSignalForTesting) Print("!!! RELAX MODE ON: StochOS=",MinStochOversold," OB=",MaxStochOverbought);
   trade.SetExpertMagicNumber(g_ActualMagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(DetectFillMode());
   hSAR_Entry      = iSAR(_Symbol,PERIOD_CURRENT,SAR_Step,SAR_Maximum);
   g_HTFHandlePeriod = ResolveHTFPeriod();
   hSAR_HTF        = iSAR(_Symbol,g_HTFHandlePeriod,    SAR_Step,SAR_Maximum);
   hBB             = iBands(_Symbol,PERIOD_CURRENT,BB_Period,BB_Shift,g_P.bb_deviation,PRICE_CLOSE);
   hRSI            = iRSI(_Symbol,PERIOD_CURRENT,RSI_Period,PRICE_CLOSE);
   hATR            = iATR(_Symbol,PERIOD_CURRENT,ATR_Period);
   hADX            = iADX(_Symbol,PERIOD_CURRENT,ADX_Period);
   hATR_MA_Regime  = iMA(_Symbol,PERIOD_CURRENT,ATR_RegimeMA_Period,0,MODE_SMA,PRICE_CLOSE);
   if(hSAR_Entry==INVALID_HANDLE||hSAR_HTF==INVALID_HANDLE||hBB==INVALID_HANDLE||
      hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE||hADX==INVALID_HANDLE||hATR_MA_Regime==INVALID_HANDLE)
   { Alert("Handle failed Err:",GetLastError()); return INIT_FAILED; }
   if(!UseRiskPercent&&NormalizeLot(LotSize)<g_VolMin){ Alert("LotSize ",LotSize," < min ",g_VolMin); return INIT_FAILED; }
   ArraySetAsSeries(sarBuf,true); ArraySetAsSeries(htfSarBuf,true);
   ArraySetAsSeries(bbUp,true);   ArraySetAsSeries(bbMid,true);   ArraySetAsSeries(bbLow,true);
   ArraySetAsSeries(rsiBuf,true); ArraySetAsSeries(atrBuf,true);  ArraySetAsSeries(atrMaBuf,true);
   ArraySetAsSeries(adxBuf,true); ArraySetAsSeries(diPlusBuf,true); ArraySetAsSeries(diMinusBuf,true);
   ArrayResize(g_PartialDoneTickets,0);
   ArrayResize(g_BreakevenDoneTickets,0);
   g_RunningEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_MaxEquity=g_RunningEquity; g_MinEquityAfterPeak=DBL_MAX;
   ArrayResize(g_EquityHistory,MathMax(EquityCurveSMA_Period+10,100));
   for(int i=0;i<ArraySize(g_EquityHistory);i++) g_EquityHistory[i]=g_RunningEquity;
   if(MinBarsRequired>0)
   { int ba=Bars(_Symbol,PERIOD_CURRENT); if(ba<MinBarsRequired) Print("!!! DATA: ",ba," bars (need ",MinBarsRequired,")"); else Print("Data OK: ",ba," bars"); }
   g_BarsAtAttach=Bars(_Symbol,PERIOD_CURRENT);
   g_SessionAsian.grossProfit=0.0;  g_SessionAsian.grossLoss=0.0;  g_SessionAsian.wins=0;  g_SessionAsian.losses=0;  g_SessionAsian.lastReset=0;
   g_SessionLondon.grossProfit=0.0; g_SessionLondon.grossLoss=0.0; g_SessionLondon.wins=0; g_SessionLondon.losses=0; g_SessionLondon.lastReset=0;
   g_SessionNY.grossProfit=0.0;     g_SessionNY.grossLoss=0.0;     g_SessionNY.wins=0;     g_SessionNY.losses=0;     g_SessionNY.lastReset=0;
   double today=TodayAsDouble();
   double storedDay=GlobalVariableCheck(GV_CapDay())?GlobalVariableGet(GV_CapDay()):0.0;
   double storedBal=GlobalVariableCheck(GV_DayStartBal())?GlobalVariableGet(GV_DayStartBal()):0.0;
   if(storedDay==today&&storedBal>0)
   {
      g_LastDay=(datetime)today; g_DayStartBalanceForCap=storedBal; g_DayStartBalance=storedBal;
      if(GlobalVariableCheck(GV_CapHit())&&GlobalVariableGet(GV_CapHit())>0.0){ g_DailyCapHit=true; Print("Cap already hit (restored)"); }
      Print("Restored persistent state");
   }
   else CheckDayReset();
   if(!ValidateInputs()) Print("Input warnings — check alert messages");
   InitSharedCap();
   PrintInit();
   if(ShouldShowDashboard())
   {
      CreateDashboard();
      UpdateDashboard();
   }
   return INIT_SUCCEEDED;
}

double OnTester()
{
   // Custom optimization target: (NetProfit / MaxDrawdown) * WinRate
   double net=g_GrossProfit-g_GrossLoss;
   double maxDD=MathMax(0.0,g_MaxEquity-g_MinEquityAfterPeak);
   double wr=(g_Total>0)?((double)g_Wins/(double)g_Total):0.0;
   if(maxDD<=0.0) return 0.0;
   return (net/maxDD)*wr;
}

//===================================================================
// DEINIT
//===================================================================
void OnDeinit(const int reason)
{
   int h[]={hSAR_Entry,hSAR_HTF,hBB,hRSI,hATR,hADX,hATR_MA_Regime};
   for(int i=0;i<ArraySize(h);i++) if(h[i]!=INVALID_HANDLE) IndicatorRelease(h[i]);
   ReleaseSharedCap();
   if(EnableCSVExport) ExportStatsToCSV();
   if(ShouldShowDashboard()) CleanupDashboard();
   CleanupSwingObjects();  // [v5.35]
   if(ShowStats) PrintFinalStats();
}

//===================================================================
// TICK
//===================================================================
void OnTick()
{
   static datetime lastBar=0;
   datetime curBar=iTime(_Symbol,PERIOD_CURRENT,0);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bool isNewBar=(curBar!=lastBar);
   bool isScalpingTF=(Period()==PERIOD_M1 || Period()==PERIOD_M5);
   int posManageInterval=ResolvePosManageIntervalSec();
   int warmUpBars=ResolveWarmUpBars();
   if(isScalpingTF || isNewBar){ UpdateFVGMitigation(bid,ask); UpdateOBMitigation(bid,ask); }
   if(EnablePositionHealthMonitor && (TimeCurrent()-g_LastPosHealthCheck)>=MathMax(60,PositionHealthCheckMinutes*60))
   {
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i); if(!t) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=g_ActualMagicNumber) continue;
         long pt=PositionGetInteger(POSITION_TYPE);
         double op=PositionGetDouble(POSITION_PRICE_OPEN);
         double sl=PositionGetDouble(POSITION_SL);
         double tp=PositionGetDouble(POSITION_TP);
         if(sl<=0.0 && g_LastATR>0.0)
         {
            double hs=(pt==POSITION_TYPE_BUY)?(op-g_P.atr_sl_multi*g_LastATR):(op+g_P.atr_sl_multi*g_LastATR);
            hs=EnforceStopLevel((pt==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL,hs,op);
            trade.PositionModify(t,hs,tp);
         }
         datetime openT=(datetime)PositionGetInteger(POSITION_TIME);
         if(MaxPositionAgeHours>0 && (TimeCurrent()-openT)>(MaxPositionAgeHours*3600))
            trade.PositionClose(t);
      }
      g_LastPosHealthCheck=TimeCurrent();
   }
   if(!ThrottleRiskChecks || TimeCurrent()-g_LastRiskChecksAt>=MathMax(1,RiskChecksIntervalSec))
   {
      CheckDayReset();
      CheckDailyProfitCap();
      CheckDailyLossUSD();
      CheckDailyTradeLimit();
      CheckFridayClose();
      g_LastRiskChecksAt=TimeCurrent();
   }
   if(isScalpingTF || TimeCurrent()-g_LastPosManageAt>=MathMax(1,posManageInterval))
   {
      ManageOpenPositions();
      g_LastPosManageAt=TimeCurrent();
   }
   if(TimeCurrent()-g_LastTicketCleanup>300){ CleanupTicketArrays(); g_LastTicketCleanup=TimeCurrent(); }
   if(!g_WarmUpComplete)
   {
      int barsSince=Bars(_Symbol,PERIOD_CURRENT)-g_BarsAtAttach;
      if(barsSince<0) barsSince=0;
      if(barsSince>=warmUpBars){ g_WarmUpComplete=true; Print("Warm-up complete"); }
      if(ShouldShowDashboard()) UpdateDashboard();
      return;
   }
   if(!isNewBar)
   {
      if(ShouldShowDashboard())
      {
         int throttle=(g_IsStrategyTester&&TesterFastDashboard)?1:5;
         static datetime lastDash=0;
         if(TimeCurrent()-lastDash>=throttle)
         {
            UpdateDashboard();
            if(g_TradingPaused!=g_LastTradingPausedState||g_TrailingStopEnabled!=g_LastTrailingState)
            { UpdateButtonStates(); g_LastTradingPausedState=g_TradingPaused; g_LastTrailingState=g_TrailingStopEnabled; }
            lastDash=TimeCurrent();
         }
      }
      return;
   }
   lastBar=curBar;
   EnsureHTFSarHandleFresh();
   InvalidateBrokenSwingLevels(iClose(_Symbol,PERIOD_CURRENT,1));
   // [v5.34 FIX-A] StochD_Confirm periodic reminder — fires every 50 bars
   // so the input cannot be silently left on after the warmup warning is missed.
   if(g_UseStochDConfirm || g_UseStochBothLines)
   {
      g_BarsSinceWarmup++;
      if(g_BarsSinceWarmup % 50 == 1)
         Print("!!! CRITICAL: StochD_Confirm=true is BLOCKING ALL TRADES. "
               "Set StochD_Confirm=false in inputs. Bar #", g_BarsSinceWarmup);
   }
   if(SafeCopyBuffer(hATR,0,0,5,atrBuf))
   {
      g_LastATR=atrBuf[1];
      DetectNewFVG(atrBuf[1]); if(EnableHTFFVG) DetectNewFVG(atrBuf[1],true); RefreshFVGBoxes();
      DetectNewOB(atrBuf[1]);  if(EnableHTFOB)  DetectNewOB(atrBuf[1],true);  RefreshOBBoxes();
      DetectSwingLevels(); RefreshSwingLines();
   }  // [v5.35]
   if(EnableSpread&&IsSpreadTooWide()){ g_Skipped++; return; }
   if(EnableSession&&!IsSessionActive()) return;
   if((EnableDailyLimit&&g_DailyLimitHit) || g_ConsecLossBreakerHit)
   {
      static datetime lastDailyLimitLog=0;
      if(lastDailyLimitLog!=curBar)
      {
         Print("Trading paused: Daily limit/breaker active until next day reset.");
         lastDailyLimitLog=curBar;
      }
      return;
   }
   if(g_DailyCapHit) return;
   if(UseNewsFilter&&IsNearNewsTime()) return;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<MinAccountBalance){ static datetime lw=0; if(curBar!=lw){ Print("Equity $",eq," < min"); lw=curBar; } return; }
   if(CheckEquityCurvePause()) return;
   if(!LoadIndicators()) return;
   double sk=0,sd=0,pk=0,pd=0;
   if(!CalcStochRSI(sk,sd,pk,pd))
   {
      if(LogStochRSIFailures && DiagnosticsMode)
         Print("StochRSI unavailable this bar.");
      return;
   }
   ENUM_TIMEFRAMES htfPeriod=ResolveHTFPeriod();
   double c1=iClose(_Symbol,PERIOD_CURRENT,1), hc1=iClose(_Symbol,htfPeriod,1), a1=atrBuf[1];
   bool buy=false, sell=false;
   double buyConf=0.0, sellConf=0.0;
   EvaluateSignals(c1,hc1,sarBuf[1],htfSarBuf[1],a1,adxBuf[1],diPlusBuf[1],diMinusBuf[1],sk,sd,pk,pd,buy,sell,buyConf,sellConf);
   if(DiagnosticsMode)
      DiagPrint(StringFormat("NewBar | Bid=%.5f ATR=%.5f Conf(B/S)=%.0f/%.0f | Trades:%d/%d",bid,g_LastATR,buyConf,sellConf,g_TodayTradeCount,MaxTradesPerDay));
   if(buy||sell)
   {
      double conf=buy?buyConf:sellConf;
      double confMinLive=ResolveConfThreshold(adxBuf[1]);
      if(!ShowConfidence||conf>=confMinLive)
      {
         datetime sigBar=iTime(_Symbol,PERIOD_CURRENT,1);
         if(buy && sigBar!=g_LastIconBuyBar)
         {
            DrawSignalIcon(true,sigBar,iHigh(_Symbol,PERIOD_CURRENT,1),iLow(_Symbol,PERIOD_CURRENT,1),a1,adxBuf[1],sk,sd,conf);
            g_LastIconBuyBar=sigBar;
         }
         if(sell && sigBar!=g_LastIconSellBar)
         {
            DrawSignalIcon(false,sigBar,iHigh(_Symbol,PERIOD_CURRENT,1),iLow(_Symbol,PERIOD_CURRENT,1),a1,adxBuf[1],sk,sd,conf);
            g_LastIconSellBar=sigBar;
         }
      }
   }
   if(g_UseCloseOnOpposite) HandleOppositeClose(buy,sell);
   int tp=CountPositions();
   bool cb=buy &&(CountPositionsByType(POSITION_TYPE_BUY) <MaxBuyPositions)&&(tp<MaxPositionsGlobal);
   bool cs=sell&&(CountPositionsByType(POSITION_TYPE_SELL)<MaxSellPositions)&&(tp<MaxPositionsGlobal);
   if(cb) OpenTrade(true, c1,a1,buyConf);
   if(cs) OpenTrade(false,c1,a1,sellConf);
   static int eqIdx=0;
   g_EquityHistory[(int)(eqIdx%ArraySize(g_EquityHistory))]=AccountInfoDouble(ACCOUNT_EQUITY);
   eqIdx++;
   if(ShouldShowDashboard())
   {
      UpdateDashboard();
      if(g_TradingPaused!=g_LastTradingPausedState||g_TrailingStopEnabled!=g_LastTrailingState)
      { UpdateButtonStates(); g_LastTradingPausedState=g_TradingPaused; g_LastTrailingState=g_TrailingStopEnabled; }
   }
}
//+------------------------------------------------------------------+
//| END — JB-Algo v5.36 — Market Watch + Swing Levels                 |
//+------------------------------------------------------------------+