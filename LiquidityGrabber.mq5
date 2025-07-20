//+------------------------------------------------------------------+
//|                      LiquidityGrabDivergence_EA.mq5              |
//|                      Dynamic Liquidity Grab System                |
//|                      Copyright 2025, FX Algo Trader              |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, FX Algo Trader"
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input group "=== Trading Hours ==="
input int TradingStartHour = 8;        // Trading Start Hour (GMT)
input int TradingEndHour = 22;         // Trading End Hour (GMT)
input bool UseNewsFilter = true;       // Use News Filter
input int NewsBufferMinutes = 30;      // Minutes Before/After News

input group "=== Risk Management ==="
input double RiskPercent = 1.0;        // Risk Per Trade (%)
input int MaxDailyTrades = 3;          // Max Trades Per Day
input int MaxPendingOrders = 3;        // Max Pending Orders
input bool StopAfterConsecutiveLoss = true;  // Stop After Consecutive Losses
input int ConsecutiveLossLimit = 2;    // Consecutive Loss Limit

input group "=== Dynamic Parameters ==="
input double ATRPeriod = 14;           // ATR Period for Dynamics
input double ExhaustionMultiplier = 2.5;  // ATR Multiplier for Exhaustion
input double GrabSizeMultiplier = 0.3;    // ATR Multiplier for Grab Size (reduced from 0.4)
input double StopMultiplier = 1.0;        // ATR Multiplier for Stop Loss
input double MinGrabGU = 5.0;          // Min Grab Size GBPUSD (pips)
input double MinGrabEU = 3.0;          // Min Grab Size EURUSD (pips)
input double MaxDistanceMultiplier = 5.0;  // Max distance in ATR multiples (increased from 3.0)

input group "=== Entry Filters ==="
input int ScoreThreshold = 5;          // Minimum Score to Trade (reduced from 6)
input bool RequireDivergence = false;  // Require Divergence
input bool UseBBExhaustion = true;     // Use Bollinger Bands Exhaustion
input int BBPeriod = 20;               // Bollinger Bands Period
input double BBDeviation = 2.0;        // Bollinger Bands Deviation

input group "=== Profit Zones GBPUSD ==="
input double GU_Zone1End = 12.0;       // Zone 1 End (pips)
input double GU_Zone2End = 18.0;       // Zone 2 End (pips)
input double GU_Zone3End = 25.0;       // Zone 3 End (pips)
input double GU_BEPips = 1.0;          // Breakeven + Pips

input group "=== Profit Zones EURUSD ==="
input double EU_Zone1End = 7.0;        // Zone 1 End (pips)
input double EU_Zone2End = 12.0;       // Zone 2 End (pips)
input double EU_Zone3End = 15.0;       // Zone 3 End (pips)
input double EU_BEPips = 1.0;          // Breakeven + Pips

input group "=== Divergence Settings ==="
input int RSI_SlowLength = 14;         // RSI Slow Length
input int RSI_FastLength = 3;          // RSI Fast Length
input int MomentumLength = 9;          // Momentum Length
input int DivLookback = 20;            // Divergence Lookback Bars
input int MinBarsBetweenDiv = 5;       // Min Bars Between Divergences

input group "=== Pending Order Settings ==="
input int OrderExpirationHours = 2;    // Pending Order Expiration (hours)
input bool CancelOnFill = true;        // Cancel Others When One Fills

//--- Global Variables
CTrade trade;
CPositionInfo position;
COrderInfo order;
CSymbolInfo m_symbol;  // Changed from 'symbol' to avoid conflicts

//--- Indicator Handles
int atrHandle;
int bbHandle;
int rsiSlowHandle;
int rsiFastHandle;

//--- Buffers
double atrBuffer[];
double bbUpper[], bbLower[], bbMiddle[];
double rsiSlowBuffer[], rsiFastBuffer[];
double compositeRSI[];

//--- Divergence Arrays
struct DivergencePoint {
    int bar;
    double price;
    double indicator;
    datetime time;
};

DivergencePoint bullishDiv[];
DivergencePoint bearishDiv[];

//--- Key Levels Structure
struct KeyLevel {
    double price;
    string name;
    datetime created;
    int strength;  // 1-5 strength rating
    bool hasOrder;
    ulong orderTicket;
};

KeyLevel supportLevels[];
KeyLevel resistanceLevels[];

//--- Trading State
struct TradingState {
    int tradesOpenedToday;
    int consecutiveLosses;
    datetime lastTradeTime;
    datetime currentDayStart;
    bool tradingEnabled;
    double dailyProfit;
    double dailyLoss;
};

TradingState state;

//--- Profit Zone Management
struct ActivePosition {
    ulong ticket;
    double entryPrice;
    int currentZone;
    datetime entryTime;
    double maxProfit;
    bool breakEvenSet;
};

ActivePosition activePositions[];

//--- News Events
struct NewsEvent {
    datetime time;
    string currency;
    string impact;
};

NewsEvent upcomingNews[];

//--- Constants
const string EA_MAGIC_STRING = "LGDEA";
const int MAGIC_NUMBER = 20250120;

// Global variable for pip calculation
double g_pipMultiplier = 1.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit() {
    Print("=== Liquidity Grab Divergence EA Initializing ===");
    
    // Set symbol
    if(!m_symbol.Name(Symbol())) {
        Alert("Failed to set symbol!");
        return INIT_FAILED;
    }
    
    // Determine pip multiplier for 5-digit brokers
    if(m_symbol.Digits() == 3 || m_symbol.Digits() == 5) {
        g_pipMultiplier = 10.0;
    } else {
        g_pipMultiplier = 1.0;
    }
    
    Print("Symbol digits: ", m_symbol.Digits(), " Pip multiplier: ", g_pipMultiplier);
    
    // Initialize trade object
    trade.SetExpertMagicNumber(MAGIC_NUMBER);
    trade.SetMarginMode();
    trade.SetTypeFillingBySymbol(Symbol());
    trade.SetDeviationInPoints(10);
    
    // Create indicators
    atrHandle = iATR(Symbol(), PERIOD_M5, (int)ATRPeriod);
    bbHandle = iBands(Symbol(), PERIOD_M5, BBPeriod, 0, BBDeviation, PRICE_CLOSE);
    rsiSlowHandle = iRSI(Symbol(), PERIOD_M5, RSI_SlowLength, PRICE_CLOSE);
    rsiFastHandle = iRSI(Symbol(), PERIOD_M5, RSI_FastLength, PRICE_CLOSE);
    
    if(atrHandle == INVALID_HANDLE || bbHandle == INVALID_HANDLE || 
       rsiSlowHandle == INVALID_HANDLE || rsiFastHandle == INVALID_HANDLE) {
        Alert("Failed to create indicators!");
        return INIT_FAILED;
    }
    
    // Initialize arrays
    ArraySetAsSeries(atrBuffer, true);
    ArraySetAsSeries(bbUpper, true);
    ArraySetAsSeries(bbLower, true);
    ArraySetAsSeries(bbMiddle, true);
    ArraySetAsSeries(rsiSlowBuffer, true);
    ArraySetAsSeries(rsiFastBuffer, true);
    ArraySetAsSeries(compositeRSI, true);
    
    // Initialize state
    ResetDailyState();
    
    // Set timer for hourly checks
    EventSetTimer(3600);
    
    Print("Initialization complete");
    Print("Symbol: ", Symbol());
    Print("ATR Period: ", ATRPeriod);
    Print("Risk per trade: ", RiskPercent, "%");
    Print("Score threshold: ", ScoreThreshold);
    Print("Max distance multiplier: ", MaxDistanceMultiplier);
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    
    // Release indicators
    IndicatorRelease(atrHandle);
    IndicatorRelease(bbHandle);
    IndicatorRelease(rsiSlowHandle);
    IndicatorRelease(rsiFastHandle);
    
    // Clean up objects
    ObjectsDeleteAll(0, EA_MAGIC_STRING);
    
    Comment("");
    Print("EA terminated. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
    // Check if new day
    CheckNewDay();
    
    // Check trading hours
    if(!IsTradingHours()) {
        return;
    }
    
    // Check if trading enabled
    if(!state.tradingEnabled) {
        Comment("Trading disabled: Consecutive losses");
        return;
    }
    
    // Update buffers
    if(!UpdateBuffers()) {
        return;
    }
    
    // Calculate composite RSI
    CalculateCompositeRSI();
    
    // Detect divergences
    DetectDivergences();
    
    // Manage existing positions
    ManageActivePositions();
    
    // Manage pending orders
    ManagePendingOrders();
    
    // Check for new levels and place orders
    if(CanPlaceNewOrders()) {
        Print("Can place new orders - checking levels...");
        IdentifyKeyLevels();
        PlacePendingOrders();
    } else {
        // Debug why we can't place orders
        static datetime lastDebugTime = 0;
        if(TimeCurrent() - lastDebugTime > 300) { // Print every 5 minutes
            Print("Cannot place orders - Daily trades: ", state.tradesOpenedToday, 
                  "/", MaxDailyTrades, " Pending: ", CountPendingOrders(), 
                  "/", MaxPendingOrders, " Active positions: ", ArraySize(activePositions));
            lastDebugTime = TimeCurrent();
        }
    }
    
    // Update display
    UpdateDashboard();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    // Update news events
    if(UseNewsFilter) {
        UpdateNewsEvents();
    }
    
    // Clean old levels
    CleanOldLevels();
}

//+------------------------------------------------------------------+
//| Trade event handler                                              |
//+------------------------------------------------------------------+
void OnTrade() {
    // Handle filled orders
    static int lastPositionCount = 0;
    int currentPositionCount = PositionsTotal();
    
    if(currentPositionCount > lastPositionCount) {
        // New position opened
        Print("New position opened from pending order");
        
        // Cancel other pending orders if configured
        if(CancelOnFill) {
            for(int i = OrdersTotal() - 1; i >= 0; i--) {
                if(order.SelectByIndex(i)) {
                    if(order.Magic() == MAGIC_NUMBER && order.Symbol() == Symbol()) {
                        trade.OrderDelete(order.Ticket());
                    }
                }
            }
        }
    }
    
    lastPositionCount = currentPositionCount;
}

//+------------------------------------------------------------------+
//| Update all indicator buffers                                     |
//+------------------------------------------------------------------+
bool UpdateBuffers() {
    int bars = 100; // Need enough for divergence detection
    
    if(CopyBuffer(atrHandle, 0, 0, bars, atrBuffer) <= 0) return false;
    if(CopyBuffer(bbHandle, 0, 0, bars, bbMiddle) <= 0) return false;
    if(CopyBuffer(bbHandle, 1, 0, bars, bbUpper) <= 0) return false;
    if(CopyBuffer(bbHandle, 2, 0, bars, bbLower) <= 0) return false;
    if(CopyBuffer(rsiSlowHandle, 0, 0, bars, rsiSlowBuffer) <= 0) return false;
    if(CopyBuffer(rsiFastHandle, 0, 0, bars, rsiFastBuffer) <= 0) return false;
    
    return true;
}

//+------------------------------------------------------------------+
//| Calculate Composite RSI (from your indicator)                    |
//+------------------------------------------------------------------+
void CalculateCompositeRSI() {
    int bars = ArraySize(rsiSlowBuffer);
    ArrayResize(compositeRSI, bars);
    
    for(int i = 0; i < bars - MomentumLength; i++) {
        double rsiDelta = rsiSlowBuffer[i] - rsiSlowBuffer[i + MomentumLength];
        
        // Simple MA of fast RSI
        double rsiSMA = 0;
        for(int j = 0; j < 3 && i + j < bars; j++) {
            rsiSMA += rsiFastBuffer[i + j];
        }
        rsiSMA /= 3;
        
        compositeRSI[i] = rsiDelta + rsiSMA;
    }
}

//+------------------------------------------------------------------+
//| Detect divergences                                               |
//+------------------------------------------------------------------+
void DetectDivergences() {
    // Clear old divergences
    ArrayResize(bullishDiv, 0);
    ArrayResize(bearishDiv, 0);
    
    // Look for bullish divergences (price lower low, indicator higher low)
    for(int i = 2; i < DivLookback; i++) {
        if(IsIndicatorTrough(i)) {
            int prevTrough = FindPreviousTrough(i + MinBarsBetweenDiv);
            if(prevTrough > 0 && prevTrough < ArraySize(compositeRSI)) {
                double priceLow1 = iLow(Symbol(), PERIOD_M5, i);
                double priceLow2 = iLow(Symbol(), PERIOD_M5, prevTrough);
                
                if(priceLow1 < priceLow2 && compositeRSI[i] > compositeRSI[prevTrough]) {
                    // Bullish divergence found
                    AddDivergence(bullishDiv, i, priceLow1, compositeRSI[i]);
                }
            }
        }
        
        // Look for bearish divergences
        if(IsIndicatorPeak(i)) {
            int prevPeak = FindPreviousPeak(i + MinBarsBetweenDiv);
            if(prevPeak > 0 && prevPeak < ArraySize(compositeRSI)) {
                double priceHigh1 = iHigh(Symbol(), PERIOD_M5, i);
                double priceHigh2 = iHigh(Symbol(), PERIOD_M5, prevPeak);
                
                if(priceHigh1 > priceHigh2 && compositeRSI[i] < compositeRSI[prevPeak]) {
                    // Bearish divergence found
                    AddDivergence(bearishDiv, i, priceHigh1, compositeRSI[i]);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check if indicator has trough                                    |
//+------------------------------------------------------------------+
bool IsIndicatorTrough(int bar) {
    if(bar <= 1 || bar >= ArraySize(compositeRSI) - 2) return false;
    
    return (compositeRSI[bar] <= compositeRSI[bar + 1] && 
            compositeRSI[bar] < compositeRSI[bar + 2] &&
            compositeRSI[bar] < compositeRSI[bar - 1]);
}

//+------------------------------------------------------------------+
//| Check if indicator has peak                                      |
//+------------------------------------------------------------------+
bool IsIndicatorPeak(int bar) {
    if(bar <= 1 || bar >= ArraySize(compositeRSI) - 2) return false;
    
    return (compositeRSI[bar] >= compositeRSI[bar + 1] && 
            compositeRSI[bar] > compositeRSI[bar + 2] &&
            compositeRSI[bar] > compositeRSI[bar - 1]);
}

//+------------------------------------------------------------------+
//| Find previous trough                                             |
//+------------------------------------------------------------------+
int FindPreviousTrough(int startBar) {
    for(int i = startBar; i < ArraySize(compositeRSI) - 2; i++) {
        if(IsIndicatorTrough(i)) {
            return i;
        }
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Find previous peak                                               |
//+------------------------------------------------------------------+
int FindPreviousPeak(int startBar) {
    for(int i = startBar; i < ArraySize(compositeRSI) - 2; i++) {
        if(IsIndicatorPeak(i)) {
            return i;
        }
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Add divergence to array                                          |
//+------------------------------------------------------------------+
void AddDivergence(DivergencePoint &divArray[], int bar, double price, double indicator) {
    int size = ArraySize(divArray);
    ArrayResize(divArray, size + 1);
    
    divArray[size].bar = bar;
    divArray[size].price = price;
    divArray[size].indicator = indicator;
    divArray[size].time = iTime(Symbol(), PERIOD_M5, bar);
}

//+------------------------------------------------------------------+
//| Identify key levels for pending orders (with debug)              |
//+------------------------------------------------------------------+
void IdentifyKeyLevels() {
    // Clear old levels
    ArrayResize(supportLevels, 0);
    ArrayResize(resistanceLevels, 0);
    
    // Refresh symbol info and get current price
    m_symbol.RefreshRates();
    double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    
    Print("=== Identifying Key Levels ===");
    Print("Current Price: ", currentPrice);
    
    // 1. Yesterday's high/low
    double yesterdayHigh = iHigh(Symbol(), PERIOD_D1, 1);
    double yesterdayLow = iLow(Symbol(), PERIOD_D1, 1);
    
    Print("Yesterday High: ", yesterdayHigh, " Low: ", yesterdayLow);
    
    if(yesterdayHigh > 0 && yesterdayLow > 0) {
        // Only add resistance if above current price
        if(yesterdayHigh > currentPrice) {
            AddLevel(resistanceLevels, yesterdayHigh, "Yesterday High", 4);
        }
        // Only add support if below current price
        if(yesterdayLow < currentPrice) {
            AddLevel(supportLevels, yesterdayLow, "Yesterday Low", 4);
        }
    }
    
    // 2. Asian session high/low (00:00 - 08:00)
    double asianHigh = GetSessionHigh(0, 8);
    double asianLow = GetSessionLow(0, 8);
    
    Print("Asian High: ", asianHigh, " Low: ", asianLow);
    
    // Validate prices before adding
    if(asianHigh > currentPrice && asianHigh != yesterdayHigh) {
        AddLevel(resistanceLevels, asianHigh, "Asian High", 3);
    }
    if(asianLow < currentPrice && asianLow != yesterdayLow) {
        AddLevel(supportLevels, asianLow, "Asian Low", 3);
    }
    
    // 3. Round numbers - Fixed for 5-digit broker
    double roundIncrement = 0.00500; // 50 pips for 5-digit
    double nearestRound = MathRound(currentPrice / roundIncrement) * roundIncrement;
    
    Print("Round increment: ", roundIncrement, " Nearest round: ", nearestRound);
    
    for(int i = -3; i <= 3; i++) {
        if(i == 0) continue;
        double level = nearestRound + (i * roundIncrement);
        
        // Only add resistance above current price
        if(level > currentPrice && MathAbs(level - currentPrice) > atrBuffer[0]) {
            AddLevel(resistanceLevels, level, "Round Number", 2);
        }
        // Only add support below current price
        else if(level < currentPrice && MathAbs(currentPrice - level) > atrBuffer[0]) {
            AddLevel(supportLevels, level, "Round Number", 2);
        }
    }
    
    // 4. Recent swing highs/lows (last 50 bars)
    FindSwingLevels();
    
    Print("Total Support Levels: ", ArraySize(supportLevels));
    for(int i = 0; i < ArraySize(supportLevels); i++) {
        Print("  Support ", i, ": ", supportLevels[i].price, " (", supportLevels[i].name, ")");
    }
    
    Print("Total Resistance Levels: ", ArraySize(resistanceLevels));
    for(int i = 0; i < ArraySize(resistanceLevels); i++) {
        Print("  Resistance ", i, ": ", resistanceLevels[i].price, " (", resistanceLevels[i].name, ")");
    }
}

//+------------------------------------------------------------------+
//| Add level to array                                               |
//+------------------------------------------------------------------+
void AddLevel(KeyLevel &levels[], double price, string name, int strength) {
    // Check if level already exists (within 5 pips)
    double tolerance = 5 * m_symbol.Point() * g_pipMultiplier;
    
    for(int i = 0; i < ArraySize(levels); i++) {
        if(MathAbs(levels[i].price - price) < tolerance) {
            // Update strength if higher
            if(strength > levels[i].strength) {
                levels[i].strength = strength;
            }
            return;
        }
    }
    
    // Add new level
    int size = ArraySize(levels);
    ArrayResize(levels, size + 1);
    
    levels[size].price = price;
    levels[size].name = name;
    levels[size].created = TimeCurrent();
    levels[size].strength = strength;
    levels[size].hasOrder = false;
    levels[size].orderTicket = 0;
}

//+------------------------------------------------------------------+
//| Place pending orders at key levels (with debug)                  |
//+------------------------------------------------------------------+
void PlacePendingOrders() {
    // Refresh rates and get current price
    m_symbol.RefreshRates();
    double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double atr = atrBuffer[0];
    
    Print("=== Checking Levels for Orders ===");
    Print("Current Price: ", currentPrice);
    Print("ATR: ", PointsToPips(atr), " pips");
    
    // Calculate dynamic parameters
    double grabSize = atr * GrabSizeMultiplier;
    double minGrab = IsGBPUSD() ? MinGrabGU * PipsToPoints() : MinGrabEU * PipsToPoints();
    grabSize = MathMax(grabSize, minGrab);
    
    double stopSize = atr * StopMultiplier;
    double minStop = m_symbol.StopsLevel() * m_symbol.Point() + grabSize;
    stopSize = MathMax(stopSize, minStop);
    
    Print("Grab Size: ", PointsToPips(grabSize), " pips");
    Print("Stop Size: ", PointsToPips(stopSize), " pips");
    
    // Process resistance levels (sell limits)
    for(int i = 0; i < ArraySize(resistanceLevels); i++) {
        if(resistanceLevels[i].hasOrder) continue;
        
        double levelPrice = resistanceLevels[i].price;
        double distance = levelPrice - currentPrice;
        
        // Skip invalid levels
        if(distance <= 0) continue;
        
        double distancePips = PointsToPips(distance);
        
        Print("Resistance: ", resistanceLevels[i].name, " at ", levelPrice, 
              " Distance: ", distancePips, " pips");
        
        // Skip if too close or too far
        if(distance < grabSize) {
            Print("  -> Too close (< grab size)");
            continue;
        }
        if(distance > atr * MaxDistanceMultiplier) {
            Print("  -> Too far (> ", MaxDistanceMultiplier, "x ATR)");
            continue;
        }
        
        // Calculate entry score
        int score = CalculateEntryScore(levelPrice, false);
        Print("  -> Score: ", score, "/", ScoreThreshold);
        
        if(score >= ScoreThreshold) {
            double entryPrice = levelPrice + grabSize;
            double sl = entryPrice + stopSize;
            double volume = CalculateLotSize(stopSize);
            
            Print("  -> Placing SELL LIMIT at ", entryPrice, " SL: ", sl);
            
            if(PlaceSellLimit(entryPrice, sl, volume, resistanceLevels[i].name)) {
                resistanceLevels[i].hasOrder = true;
            }
        }
    }
    
    // Process support levels (buy limits)
    for(int i = 0; i < ArraySize(supportLevels); i++) {
        if(supportLevels[i].hasOrder) continue;
        
        double levelPrice = supportLevels[i].price;
        double distance = currentPrice - levelPrice;
        
        // Skip invalid levels
        if(distance <= 0) continue;
        
        double distancePips = PointsToPips(distance);
        
        Print("Support: ", supportLevels[i].name, " at ", levelPrice, 
              " Distance: ", distancePips, " pips");
        
        // Skip if too close or too far
        if(distance < grabSize) {
            Print("  -> Too close (< grab size)");
            continue;
        }
        if(distance > atr * MaxDistanceMultiplier) {
            Print("  -> Too far (> ", MaxDistanceMultiplier, "x ATR)");
            continue;
        }
        
        // Calculate entry score
        int score = CalculateEntryScore(levelPrice, true);
        Print("  -> Score: ", score, "/", ScoreThreshold);
        
        if(score >= ScoreThreshold) {
            double entryPrice = levelPrice - grabSize;
            double sl = entryPrice - stopSize;
            double volume = CalculateLotSize(stopSize);
            
            Print("  -> Placing BUY LIMIT at ", entryPrice, " SL: ", sl);
            
            if(PlaceBuyLimit(entryPrice, sl, volume, supportLevels[i].name)) {
                supportLevels[i].hasOrder = true;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate entry score                                            |
//+------------------------------------------------------------------+
int CalculateEntryScore(double levelPrice, bool isBuy) {
    int score = 0;
    
    m_symbol.RefreshRates();
    double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    
    Print("  Calculating score for ", isBuy ? "BUY" : "SELL", " at ", levelPrice);
    
    // 1. Level strength (already calculated)
    int levelStrength = 0;
    if(isBuy) {
        for(int i = 0; i < ArraySize(supportLevels); i++) {
            if(MathAbs(supportLevels[i].price - levelPrice) < 5 * PipsToPoints()) {
                levelStrength = supportLevels[i].strength;
                break;
            }
        }
    } else {
        for(int i = 0; i < ArraySize(resistanceLevels); i++) {
            if(MathAbs(resistanceLevels[i].price - levelPrice) < 5 * PipsToPoints()) {
                levelStrength = resistanceLevels[i].strength;
                break;
            }
        }
    }
    score += levelStrength;
    Print("    Level strength: ", levelStrength);
    
    // 2. Check for divergence (2 points)
    if(HasRecentDivergence(isBuy)) {
        score += 2;
        Print("    Divergence found: +2");
    }
    
    // 3. BB Exhaustion (2 points)
    if(UseBBExhaustion && ArraySize(bbUpper) > 0 && ArraySize(bbLower) > 0) {
        if(isBuy && currentPrice < bbLower[0]) {
            score += 2;
            Print("    BB exhaustion (below lower): +2");
        }
        else if(!isBuy && currentPrice > bbUpper[0]) {
            score += 2;
            Print("    BB exhaustion (above upper): +2");
        }
    }
    
    // 4. Momentum slowing (1 point)
    if(IsMomentumSlowing(isBuy)) {
        score += 1;
        Print("    Momentum slowing: +1");
    }
    
    // 5. Exhaustion move (1 point)
    double recentMove = GetRecentMove();
    double exhaustionThreshold = atrBuffer[0] * ExhaustionMultiplier;
    if(MathAbs(recentMove) > exhaustionThreshold) {
        score += 1;
        Print("    Exhaustion move (", PointsToPips(recentMove), " pips > ", 
              PointsToPips(exhaustionThreshold), " pips): +1");
    }
    
    return score;
}

//+------------------------------------------------------------------+
//| Check for recent divergence                                      |
//+------------------------------------------------------------------+
bool HasRecentDivergence(bool bullish) {
    if(bullish) {
        for(int i = 0; i < ArraySize(bullishDiv); i++) {
            if(bullishDiv[i].bar < 10) { // Within 10 bars
                return true;
            }
        }
    } else {
        for(int i = 0; i < ArraySize(bearishDiv); i++) {
            if(bearishDiv[i].bar < 10) {
                return true;
            }
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Check if momentum is slowing                                     |
//+------------------------------------------------------------------+
bool IsMomentumSlowing(bool forBuy) {
    if(ArraySize(compositeRSI) < 5) return false;
    
    if(forBuy) {
        // For buy, check if RSI is rising from oversold
        return (compositeRSI[0] > compositeRSI[2] && compositeRSI[0] < 40);
    } else {
        // For sell, check if RSI is falling from overbought
        return (compositeRSI[0] < compositeRSI[2] && compositeRSI[0] > 60);
    }
}

//+------------------------------------------------------------------+
//| Place buy limit order                                            |
//+------------------------------------------------------------------+
bool PlaceBuyLimit(double price, double sl, double volume, string comment) {
    // Validate prices
    if(price <= 0 || sl <= 0 || price >= SymbolInfoDouble(Symbol(), SYMBOL_ASK)) {
        Print("Invalid buy limit price: ", price, " SL: ", sl, " Ask: ", SymbolInfoDouble(Symbol(), SYMBOL_ASK));
        return false;
    }
    
    datetime expiration = TimeCurrent() + OrderExpirationHours * 3600;
    string fullComment = EA_MAGIC_STRING + "|" + comment;
    
    if(trade.BuyLimit(volume, price, Symbol(), sl, 0, ORDER_TIME_SPECIFIED, expiration, fullComment)) {
        Print("Buy limit placed at ", price, " for ", comment);
        return true;
    }
    
    Print("Failed to place buy limit: ", trade.ResultRetcode());
    return false;
}

//+------------------------------------------------------------------+
//| Place sell limit order                                           |
//+------------------------------------------------------------------+
bool PlaceSellLimit(double price, double sl, double volume, string comment) {
    // Validate prices
    if(price <= 0 || sl <= 0 || price <= SymbolInfoDouble(Symbol(), SYMBOL_BID)) {
        Print("Invalid sell limit price: ", price, " SL: ", sl, " Bid: ", SymbolInfoDouble(Symbol(), SYMBOL_BID));
        return false;
    }
    
    datetime expiration = TimeCurrent() + OrderExpirationHours * 3600;
    string fullComment = EA_MAGIC_STRING + "|" + comment;
    
    if(trade.SellLimit(volume, price, Symbol(), sl, 0, ORDER_TIME_SPECIFIED, expiration, fullComment)) {
        Print("Sell limit placed at ", price, " for ", comment);
        return true;
    }
    
    Print("Failed to place sell limit: ", trade.ResultRetcode());
    return false;
}

//+------------------------------------------------------------------+
//| Manage active positions with profit zones                        |
//+------------------------------------------------------------------+
void ManageActivePositions() {
    // Update active positions array
    UpdateActivePositions();
    
    for(int i = 0; i < ArraySize(activePositions); i++) {
        if(!position.SelectByTicket(activePositions[i].ticket)) continue;
        
        double currentProfit = position.Profit();
        double priceMove = 0;
        
        if(position.PositionType() == POSITION_TYPE_BUY) {
            priceMove = PointsToPips(SymbolInfoDouble(Symbol(), SYMBOL_BID) - position.PriceOpen());
        } else {
            priceMove = PointsToPips(position.PriceOpen() - SymbolInfoDouble(Symbol(), SYMBOL_ASK));
        }
        
        // Update max profit
        if(priceMove > activePositions[i].maxProfit) {
            activePositions[i].maxProfit = priceMove;
        }
        
        // Get zone boundaries
        double zone1End, zone2End, zone3End, bePips;
        GetZoneBoundaries(zone1End, zone2End, zone3End, bePips);
        
        // Determine current zone
        int newZone = 0;
        if(priceMove >= zone3End) newZone = 4;
        else if(priceMove >= zone2End) newZone = 3;
        else if(priceMove >= zone1End) newZone = 2;
        else newZone = 1;
        
        // Zone management
        if(newZone > activePositions[i].currentZone) {
            activePositions[i].currentZone = newZone;
            Print("Position ", activePositions[i].ticket, " entered Zone ", newZone);
            
            // Handle zone transitions
            switch(newZone) {
                case 2:
                    // Move to breakeven
                    if(!activePositions[i].breakEvenSet) {
                        MoveToBreakeven(position, bePips);
                        activePositions[i].breakEvenSet = true;
                    }
                    break;
                    
                case 3:
                    // Trail stop to protect more profit
                    TrailStop(position, zone1End);
                    break;
                    
                case 4:
                    // Look for exit at next level
                    CheckZone4Exit(position);
                    break;
            }
        }
        
        // Check exit conditions based on zone
        if(ShouldExitPosition(activePositions[i], position, priceMove)) {
            ClosePosition(position);
        }
    }
}

//+------------------------------------------------------------------+
//| Check if should exit position                                    |
//+------------------------------------------------------------------+
bool ShouldExitPosition(ActivePosition &pos, CPositionInfo &posInfo, double priceMove) {
    // Zone-based exit rules
    switch(pos.currentZone) {
        case 1:
            // In Zone 1, only exit on stop loss
            return false;
            
        case 2:
        case 3:
            // Check for reversal signals
            if(CheckReversalSignal(posInfo, pos.currentZone)) {
                Print("Reversal signal detected in Zone ", pos.currentZone);
                return true;
            }
            
            // Check structure break
            if(CheckStructureBreak(posInfo)) {
                Print("Structure break detected");
                return true;
            }
            break;
            
        case 4:
            // Exit at next major level or reversal
            if(AtNextMajorLevel(posInfo) || CheckReversalSignal(posInfo, 4)) {
                Print("Zone 4 exit condition met");
                return true;
            }
            break;
    }
    
    // Time-based exit for stalled trades
    int entryBar = iBarShift(Symbol(), PERIOD_M5, pos.entryTime);
    int currentBar = 0;  // Current bar is always 0
    int barsInTrade = entryBar - currentBar;
    
    if(barsInTrade > 9 && priceMove < GetZone1End()) { // 45 mins with no progress
        Print("Time-based exit: Trade stalled");
        return true;
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Check for reversal signal                                        |
//+------------------------------------------------------------------+
bool CheckReversalSignal(CPositionInfo &pos, int zone) {
    bool isBuy = pos.PositionType() == POSITION_TYPE_BUY;
    
    // Get minimum reversal size based on zone
    double minReversalSize = 0;
    if(zone == 2) {
        minReversalSize = IsGBPUSD() ? 8 : 5;
    }
    else if(zone >= 3) {
        minReversalSize = IsGBPUSD() ? 6 : 4;
    }
    
    // Check last candle
    double open = iOpen(Symbol(), PERIOD_M5, 1);
    double close = iClose(Symbol(), PERIOD_M5, 1);
    double high = iHigh(Symbol(), PERIOD_M5, 1);
    double low = iLow(Symbol(), PERIOD_M5, 1);
    
    double candleSize = PointsToPips(MathAbs(close - open));
    
    if(isBuy) {
        // Bearish reversal candle
        if(close < open && candleSize >= minReversalSize) {
            // Check if it's erasing our profit
            double profitErased = PointsToPips(high - close);
            if(profitErased > minReversalSize * 0.5) {
                return true;
            }
        }
    } else {
        // Bullish reversal candle
        if(close > open && candleSize >= minReversalSize) {
            double profitErased = PointsToPips(close - low);
            if(profitErased > minReversalSize * 0.5) {
                return true;
            }
        }
    }
    
    // Check momentum reversal
    if(ArraySize(compositeRSI) > 2) {
        if(isBuy && compositeRSI[0] < compositeRSI[1] && compositeRSI[1] < compositeRSI[2]) {
            return true;
        }
        else if(!isBuy && compositeRSI[0] > compositeRSI[1] && compositeRSI[1] > compositeRSI[2]) {
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossDistance) {
    double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
    double tickValue = m_symbol.TickValue();
    double lotSize = riskAmount / (stopLossDistance / m_symbol.Point() * tickValue);
    
    // Normalize to broker requirements
    double minLot = m_symbol.LotsMin();
    double maxLot = m_symbol.LotsMax();
    double lotStep = m_symbol.LotsStep();
    
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
    lotSize = MathRound(lotSize / lotStep) * lotStep;
    
    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Update dashboard                                                 |
//+------------------------------------------------------------------+
void UpdateDashboard() {
    string status = state.tradingEnabled ? "ACTIVE" : "STOPPED";
    string timeStatus = IsTradingHours() ? "Market Open" : "Market Closed";
    
    int pendingOrders = CountPendingOrders();
    int activePos = ArraySize(activePositions);
    
    string divergenceStatus = "Bull: " + IntegerToString(ArraySize(bullishDiv)) + 
                             " Bear: " + IntegerToString(ArraySize(bearishDiv));
    
    double dailyPnL = state.dailyProfit - state.dailyLoss;
    
    Comment(
        "=== Liquidity Grab Divergence EA ===\n",
        "Status: ", status, " | ", timeStatus, "\n",
        "Daily Trades: ", state.tradesOpenedToday, "/", MaxDailyTrades, "\n",
        "Consecutive Losses: ", state.consecutiveLosses, "\n",
        "Daily P/L: ", DoubleToString(dailyPnL, 2), "\n",
        "Active Positions: ", activePos, " | Pending: ", pendingOrders, "\n",
        "Divergences: ", divergenceStatus, "\n",
        "ATR: ", DoubleToString(PointsToPips(atrBuffer[0]), 1), " pips\n",
        "Levels - Support: ", ArraySize(supportLevels), " Resistance: ", ArraySize(resistanceLevels)
    );
}

//+------------------------------------------------------------------+
//| Helper functions                                                 |
//+------------------------------------------------------------------+
bool IsGBPUSD() {
    string sym = Symbol();  // Use Symbol() directly
    return (StringFind(sym, "GBPUSD") >= 0 || StringFind(sym, "GBP/USD") >= 0);
}

bool IsTradingHours() {
    MqlDateTime time;
    TimeToStruct(TimeCurrent(), time);
    
    if(time.hour < TradingStartHour || time.hour >= TradingEndHour) {
        return false;
    }
    
    // Check news filter
    if(UseNewsFilter && IsNewsTime()) {
        return false;
    }
    
    return true;
}

void GetZoneBoundaries(double &zone1, double &zone2, double &zone3, double &be) {
    if(IsGBPUSD()) {
        zone1 = GU_Zone1End;
        zone2 = GU_Zone2End;
        zone3 = GU_Zone3End;
        be = GU_BEPips;
    } else {
        zone1 = EU_Zone1End;
        zone2 = EU_Zone2End;
        zone3 = EU_Zone3End;
        be = EU_BEPips;
    }
}

double GetZone1End() {
    return IsGBPUSD() ? GU_Zone1End : EU_Zone1End;
}

//+------------------------------------------------------------------+
//| Pip conversion helpers                                           |
//+------------------------------------------------------------------+
double PipsToPoints() {
    return m_symbol.Point() * g_pipMultiplier;
}

double PointsToPips(double points) {
    return points / (m_symbol.Point() * g_pipMultiplier);
}

//+------------------------------------------------------------------+
//| Reset daily state                                                |
//+------------------------------------------------------------------+
void ResetDailyState() {
    state.tradesOpenedToday = 0;
    state.consecutiveLosses = 0;
    state.lastTradeTime = 0;
    state.currentDayStart = TimeCurrent();
    state.tradingEnabled = true;
    state.dailyProfit = 0;
    state.dailyLoss = 0;
}

//+------------------------------------------------------------------+
//| Check for new day                                                |
//+------------------------------------------------------------------+
void CheckNewDay() {
    MqlDateTime currentTime, stateTime;
    TimeToStruct(TimeCurrent(), currentTime);
    TimeToStruct(state.currentDayStart, stateTime);
    
    if(currentTime.day != stateTime.day) {
        ResetDailyState();
        Print("New trading day started");
    }
}

//+------------------------------------------------------------------+
//| Manage pending orders                                            |
//+------------------------------------------------------------------+
void ManagePendingOrders() {
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        if(order.SelectByIndex(i)) {
            if(order.Magic() != MAGIC_NUMBER) continue;
            if(order.Symbol() != Symbol()) continue;
            
            // Check if order expired naturally
            if(order.State() == ORDER_STATE_EXPIRED) {
                // Update level status
                UpdateLevelOrderStatus(order.PriceOpen(), false);
            }
            
            // Cancel other orders if one filled (if enabled)
            if(CancelOnFill && ArraySize(activePositions) > 0) {
                if(trade.OrderDelete(order.Ticket())) {
                    UpdateLevelOrderStatus(order.PriceOpen(), false);
                    Print("Cancelled pending order: ", order.Ticket());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check if can place new orders                                   |
//+------------------------------------------------------------------+
bool CanPlaceNewOrders() {
    // Check daily limit
    if(state.tradesOpenedToday >= MaxDailyTrades) {
        return false;
    }
    
    // Check pending orders limit
    if(CountPendingOrders() >= MaxPendingOrders) {
        return false;
    }
    
    // Check if we have active positions
    if(ArraySize(activePositions) > 0 && CancelOnFill) {
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Update news events (placeholder)                                 |
//+------------------------------------------------------------------+
void UpdateNewsEvents() {
    // This would connect to a news service
    // For now, just clear old events
    ArrayResize(upcomingNews, 0);
    
    // Example: Add some dummy news events for testing
    // In real implementation, this would fetch from economic calendar
}

//+------------------------------------------------------------------+
//| Clean old levels                                                 |
//+------------------------------------------------------------------+
void CleanOldLevels() {
    datetime cutoffTime = TimeCurrent() - 24 * 3600; // 24 hours old
    
    // Clean support levels
    for(int i = ArraySize(supportLevels) - 1; i >= 0; i--) {
        if(supportLevels[i].created < cutoffTime && !supportLevels[i].hasOrder) {
            ArrayRemove(supportLevels, i, 1);
        }
    }
    
    // Clean resistance levels
    for(int i = ArraySize(resistanceLevels) - 1; i >= 0; i--) {
        if(resistanceLevels[i].created < cutoffTime && !resistanceLevels[i].hasOrder) {
            ArrayRemove(resistanceLevels, i, 1);
        }
    }
}

//+------------------------------------------------------------------+
//| Get session high                                                 |
//+------------------------------------------------------------------+
double GetSessionHigh(int startHour, int endHour) {
    MqlDateTime timeStruct;
    TimeToStruct(TimeCurrent(), timeStruct);
    
    datetime startTime = TimeCurrent() - (TimeCurrent() % 86400) + startHour * 3600;
    datetime endTime = TimeCurrent() - (TimeCurrent() % 86400) + endHour * 3600;
    
    if(startTime > TimeCurrent()) startTime -= 86400;
    if(endTime > TimeCurrent()) endTime = TimeCurrent();
    
    int startBar = iBarShift(Symbol(), PERIOD_M5, startTime);
    int endBar = iBarShift(Symbol(), PERIOD_M5, endTime);
    
    if(startBar < 0 || endBar < 0) return 0;
    
    double high = 0;
    for(int i = endBar; i <= startBar && i < iBars(Symbol(), PERIOD_M5); i++) {
        double barHigh = iHigh(Symbol(), PERIOD_M5, i);
        if(barHigh > high) high = barHigh;
    }
    
    return high;
}

//+------------------------------------------------------------------+
//| Get session low                                                  |
//+------------------------------------------------------------------+
double GetSessionLow(int startHour, int endHour) {
    MqlDateTime timeStruct;
    TimeToStruct(TimeCurrent(), timeStruct);
    
    datetime startTime = TimeCurrent() - (TimeCurrent() % 86400) + startHour * 3600;
    datetime endTime = TimeCurrent() - (TimeCurrent() % 86400) + endHour * 3600;
    
    if(startTime > TimeCurrent()) startTime -= 86400;
    if(endTime > TimeCurrent()) endTime = TimeCurrent();
    
    int startBar = iBarShift(Symbol(), PERIOD_M5, startTime);
    int endBar = iBarShift(Symbol(), PERIOD_M5, endTime);
    
    if(startBar < 0 || endBar < 0) return 0;
    
    double low = iLow(Symbol(), PERIOD_M5, endBar);  // Initialize with first bar
    if(low <= 0) return 0;
    
    for(int i = endBar; i <= startBar && i < iBars(Symbol(), PERIOD_M5); i++) {
        double barLow = iLow(Symbol(), PERIOD_M5, i);
        if(barLow > 0 && barLow < low) low = barLow;
    }
    
    return low > 0 ? low : 0;
}

//+------------------------------------------------------------------+
//| Find swing levels                                                |
//+------------------------------------------------------------------+
void FindSwingLevels() {
    int lookback = 50;
    int swingHighCount = 0;
    int swingLowCount = 0;
    
    double currentPrice = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    
    for(int i = 3; i < lookback; i++) {
        // Check for swing high
        double high = iHigh(Symbol(), PERIOD_M5, i);
        double high1 = iHigh(Symbol(), PERIOD_M5, i + 1);
        double high2 = iHigh(Symbol(), PERIOD_M5, i + 2);
        double high_1 = iHigh(Symbol(), PERIOD_M5, i - 1);
        double high_2 = iHigh(Symbol(), PERIOD_M5, i - 2);
        
        if(high > high1 && high > high2 && high > high_1 && high > high_2) {
            // Only add if above current price
            if(high > currentPrice) {
                AddLevel(resistanceLevels, high, "Swing High", 3);
                swingHighCount++;
            }
        }
        
        // Check for swing low
        double low = iLow(Symbol(), PERIOD_M5, i);
        double low1 = iLow(Symbol(), PERIOD_M5, i + 1);
        double low2 = iLow(Symbol(), PERIOD_M5, i + 2);
        double low_1 = iLow(Symbol(), PERIOD_M5, i - 1);
        double low_2 = iLow(Symbol(), PERIOD_M5, i - 2);
        
        if(low < low1 && low < low2 && low < low_1 && low < low_2) {
            // Only add if below current price
            if(low < currentPrice) {
                AddLevel(supportLevels, low, "Swing Low", 3);
                swingLowCount++;
            }
        }
    }
    
    Print("Found ", swingHighCount, " swing highs and ", swingLowCount, " swing lows");
}

//+------------------------------------------------------------------+
//| Get recent price move                                            |
//+------------------------------------------------------------------+
double GetRecentMove() {
    int bars = 20; // Look at last 20 bars
    double high = iHigh(Symbol(), PERIOD_M5, iHighest(Symbol(), PERIOD_M5, MODE_HIGH, bars, 0));
    double low = iLow(Symbol(), PERIOD_M5, iLowest(Symbol(), PERIOD_M5, MODE_LOW, bars, 0));
    return high - low;
}

//+------------------------------------------------------------------+
//| Update active positions array                                    |
//+------------------------------------------------------------------+
void UpdateActivePositions() {
    ArrayResize(activePositions, 0);
    
    for(int i = 0; i < PositionsTotal(); i++) {
        if(position.SelectByIndex(i)) {
            if(position.Magic() != MAGIC_NUMBER) continue;
            if(position.Symbol() != Symbol()) continue;
            
            // Check if already in array
            bool found = false;
            for(int j = 0; j < ArraySize(activePositions); j++) {
                if(activePositions[j].ticket == position.Ticket()) {
                    found = true;
                    break;
                }
            }
            
            if(!found) {
                // Add new position
                int size = ArraySize(activePositions);
                ArrayResize(activePositions, size + 1);
                
                activePositions[size].ticket = position.Ticket();
                activePositions[size].entryPrice = position.PriceOpen();
                activePositions[size].currentZone = 1;
                activePositions[size].entryTime = position.Time();
                activePositions[size].maxProfit = 0;
                activePositions[size].breakEvenSet = false;
                
                // Update daily stats
                state.tradesOpenedToday++;
                state.lastTradeTime = TimeCurrent();
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Move position to breakeven                                       |
//+------------------------------------------------------------------+
void MoveToBreakeven(CPositionInfo &pos, double bePips) {
    double newSL = 0;
    double currentSL = pos.StopLoss();
    double openPrice = pos.PriceOpen();
    
    if(pos.PositionType() == POSITION_TYPE_BUY) {
        newSL = openPrice + bePips * PipsToPoints();
        if(newSL > currentSL && SymbolInfoDouble(Symbol(), SYMBOL_BID) > newSL + 10 * m_symbol.Point()) {
            if(trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit())) {
                Print("Moved to BE+", bePips, " for ticket ", pos.Ticket());
            }
        }
    } else {
        newSL = openPrice - bePips * PipsToPoints();
        if(newSL < currentSL && SymbolInfoDouble(Symbol(), SYMBOL_ASK) < newSL - 10 * m_symbol.Point()) {
            if(trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit())) {
                Print("Moved to BE+", bePips, " for ticket ", pos.Ticket());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trail stop loss                                                  |
//+------------------------------------------------------------------+
void TrailStop(CPositionInfo &pos, double minPips) {
    double newSL = 0;
    double currentSL = pos.StopLoss();
    double trailDistance = minPips * PipsToPoints();
    
    if(pos.PositionType() == POSITION_TYPE_BUY) {
        newSL = SymbolInfoDouble(Symbol(), SYMBOL_BID) - trailDistance;
        if(newSL > currentSL) {
            if(trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit())) {
                Print("Trailed stop to ", newSL, " for ticket ", pos.Ticket());
            }
        }
    } else {
        newSL = SymbolInfoDouble(Symbol(), SYMBOL_ASK) + trailDistance;
        if(newSL < currentSL) {
            if(trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit())) {
                Print("Trailed stop to ", newSL, " for ticket ", pos.Ticket());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check for Zone 4 exit conditions                                |
//+------------------------------------------------------------------+
void CheckZone4Exit(CPositionInfo &pos) {
    // In Zone 4, we're looking for the next major level
    double currentPrice = pos.PositionType() == POSITION_TYPE_BUY ? 
                         SymbolInfoDouble(Symbol(), SYMBOL_BID) : 
                         SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    
    // Check against major levels
    if(pos.PositionType() == POSITION_TYPE_BUY) {
        for(int i = 0; i < ArraySize(resistanceLevels); i++) {
            if(MathAbs(currentPrice - resistanceLevels[i].price) < 5 * PipsToPoints()) {
                ClosePosition(pos);
                return;
            }
        }
    } else {
        for(int i = 0; i < ArraySize(supportLevels); i++) {
            if(MathAbs(currentPrice - supportLevels[i].price) < 5 * PipsToPoints()) {
                ClosePosition(pos);
                return;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Close position                                                   |
//+------------------------------------------------------------------+
void ClosePosition(CPositionInfo &pos) {
    if(trade.PositionClose(pos.Ticket())) {
        Print("Position closed: ", pos.Ticket());
        
        // Update stats
        double profit = pos.Profit();
        if(profit > 0) {
            state.dailyProfit += profit;
            state.consecutiveLosses = 0;
        } else {
            state.dailyLoss += MathAbs(profit);
            state.consecutiveLosses++;
            
            // Check if should stop trading
            if(StopAfterConsecutiveLoss && state.consecutiveLosses >= ConsecutiveLossLimit) {
                state.tradingEnabled = false;
                Print("Trading stopped: Consecutive loss limit reached");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check structure break                                            |
//+------------------------------------------------------------------+
bool CheckStructureBreak(CPositionInfo &pos) {
    bool isBuy = pos.PositionType() == POSITION_TYPE_BUY;
    
    // Look at last 5 bars for structure
    if(isBuy) {
        // For buy, check if we made a lower low
        double lowestLow = iLow(Symbol(), PERIOD_M5, 1);
        for(int i = 2; i <= 5; i++) {
            if(iLow(Symbol(), PERIOD_M5, i) < lowestLow) {
                return false; // No break yet
            }
        }
        
        // Current bar making lower low?
        if(SymbolInfoDouble(Symbol(), SYMBOL_BID) < lowestLow) {
            return true;
        }
    } else {
        // For sell, check if we made a higher high
        double highestHigh = iHigh(Symbol(), PERIOD_M5, 1);
        for(int i = 2; i <= 5; i++) {
            if(iHigh(Symbol(), PERIOD_M5, i) > highestHigh) {
                return false; // No break yet
            }
        }
        
        // Current bar making higher high?
        if(SymbolInfoDouble(Symbol(), SYMBOL_ASK) > highestHigh) {
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Check if at next major level                                     |
//+------------------------------------------------------------------+
bool AtNextMajorLevel(CPositionInfo &pos) {
    double currentPrice = pos.PositionType() == POSITION_TYPE_BUY ? 
                         SymbolInfoDouble(Symbol(), SYMBOL_BID) : 
                         SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double entryPrice = pos.PriceOpen();
    
    // Check against levels
    if(pos.PositionType() == POSITION_TYPE_BUY) {
        for(int i = 0; i < ArraySize(resistanceLevels); i++) {
            if(resistanceLevels[i].price > entryPrice && 
               MathAbs(currentPrice - resistanceLevels[i].price) < 5 * PipsToPoints()) {
                return true;
            }
        }
    } else {
        for(int i = 0; i < ArraySize(supportLevels); i++) {
            if(supportLevels[i].price < entryPrice && 
               MathAbs(currentPrice - supportLevels[i].price) < 5 * PipsToPoints()) {
                return true;
            }
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Count pending orders                                             |
//+------------------------------------------------------------------+
int CountPendingOrders() {
    int count = 0;
    
    for(int i = 0; i < OrdersTotal(); i++) {
        if(order.SelectByIndex(i)) {
            if(order.Magic() == MAGIC_NUMBER && order.Symbol() == Symbol()) {
                count++;
            }
        }
    }
    
    return count;
}

//+------------------------------------------------------------------+
//| Check if news time                                              |
//+------------------------------------------------------------------+
bool IsNewsTime() {
    // Simple implementation - would need real news calendar integration
    datetime currentTime = TimeCurrent();
    
    for(int i = 0; i < ArraySize(upcomingNews); i++) {
        if(currentTime >= upcomingNews[i].time - NewsBufferMinutes * 60 &&
           currentTime <= upcomingNews[i].time + NewsBufferMinutes * 60) {
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Update level order status                                        |
//+------------------------------------------------------------------+
void UpdateLevelOrderStatus(double price, bool hasOrder) {
    double tolerance = 5 * PipsToPoints();
    
    // Update support levels
    for(int i = 0; i < ArraySize(supportLevels); i++) {
        if(MathAbs(supportLevels[i].price - price) < tolerance) {
            supportLevels[i].hasOrder = hasOrder;
            return;
        }
    }
    
    // Update resistance levels
    for(int i = 0; i < ArraySize(resistanceLevels); i++) {
        if(MathAbs(resistanceLevels[i].price - price) < tolerance) {
            resistanceLevels[i].hasOrder = hasOrder;
            return;
        }
    }
}

//+------------------------------------------------------------------+