//+------------------------------------------------------------------+
//| XAUUSD Autopilot EA (MT5)                                        |
//| Trend-following breakout with ATR risk sizing + ATR trailing      |
//| - Donchian breakout entry (N bars)                               |
//| - EMA trend filter + RSI regime filter                           |
//| - ATR-based SL + optional TP (R-multiple)                        |
//| - Break-even + ATR trailing after profit threshold               |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// -------------------- Inputs --------------------
input string InpSymbol              = "XAUUSD";      // Trading symbol (must match Market Watch)
input ENUM_TIMEFRAMES InpTF         = PERIOD_M15;    // Signal timeframe
input int    InpDonchianLen         = 20;            // Donchian length (breakout)
input int    InpExitLen             = 10;            // Donchian exit length (optional exit)
input int    InpEMA                 = 200;           // EMA period (trend filter)
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H1;     // Trend filter timeframe
input int    InpRSIPeriod           = 14;            // RSI period
input double InpRSI_BuyMin          = 52.0;          // Buy only if RSI >= this
input double InpRSI_SellMax         = 48.0;          // Sell only if RSI <= this

input int    InpATRPeriod           = 14;            // ATR period
input double InpSL_ATR_Mult         = 2.5;           // Initial SL = ATR * mult
input bool   InpUseTP               = true;          // Use Take Profit?
input double InpTP_R_Mult           = 2.0;           // TP = R multiple (R = entry->SL distance)

input bool   InpRiskBasedLot        = true;          // Use risk-based sizing?
input double InpRiskPercent         = 0.75;          // % equity risked per trade (e.g., 0.5 to 1.0)
input double InpFixedLot            = 0.05;          // Fixed lot if risk-based disabled

input bool   InpOneTradeAtATime     = true;          // Only one position at a time on symbol+magic
input long   InpMagic               = 260223;        // Magic number

input int    InpMaxSpreadPoints     = 300;           // Max spread (points) to allow entry
input bool   InpUseSessionFilter    = false;         // Trade only certain hours?
input int    InpStartHour           = 6;             // Start hour (server time)
input int    InpEndHour             = 22;            // End hour (server time)

input bool   InpUseBreakEven        = true;          // Move SL to breakeven after profit threshold?
input double InpBE_AtR              = 1.0;           // Break-even when profit >= X * R
input bool   InpUseATRTrail         = true;          // ATR trailing stop?
input double InpTrail_ATR_Mult      = 2.0;           // Trail distance = ATR * mult
input double InpTrailStartR         = 1.2;           // Start trailing when profit >= X * R

// -------------------- Globals --------------------
int hATR = INVALID_HANDLE;
int hEMA = INVALID_HANDLE;
int hRSI = INVALID_HANDLE;

datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Utility: check session hours                                     |
//+------------------------------------------------------------------+
bool SessionOK()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime tm; TimeToStruct(TimeCurrent(), tm);
   int h = tm.hour;

   if(InpStartHour <= InpEndHour)
      return (h >= InpStartHour && h < InpEndHour);

   // overnight window
   return (h >= InpStartHour || h < InpEndHour);
}

//+------------------------------------------------------------------+
//| Utility: spread filter                                           |
//+------------------------------------------------------------------+
bool SpreadOK(const string sym)
{
   int spread = (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);
   return (spread > 0 && spread <= InpMaxSpreadPoints);
}

//+------------------------------------------------------------------+
//| Utility: normalize volume to broker constraints                  |
//+------------------------------------------------------------------+
double NormalizeVolume(const string sym, double vol)
{
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   if(vol < vmin) vol = vmin;
   if(vol > vmax) vol = vmax;

   // snap to step
   double steps = MathFloor((vol - vmin) / step + 0.5);
   double v = vmin + steps * step;

   if(v < vmin) v = vmin;
   if(v > vmax) v = vmax;

   return v;
}

//+------------------------------------------------------------------+
//| Utility: get indicator value (buffer 0, shift)                   |
//+------------------------------------------------------------------+
bool GetIndVal(const int handle, const int shift, double &outVal)
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1) return false;
   outVal = buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| Utility: get Donchian high/low excluding current bar             |
//+------------------------------------------------------------------+
bool GetDonchian(const string sym, ENUM_TIMEFRAMES tf, int len, double &upper, double &lower)
{
   if(len < 2) return false;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   // bars: shift 1..len (exclude current forming bar at shift 0)
   int need = len + 2;
   int got = CopyRates(sym, tf, 0, need, rates);
   if(got < len + 1) return false;

   upper = rates[1].high;
   lower = rates[1].low;

   for(int i = 1; i <= len; i++)
   {
      if(rates[i].high > upper) upper = rates[i].high;
      if(rates[i].low  < lower) lower = rates[i].low;
   }
   return true;
}

//+------------------------------------------------------------------+
//| FIX: Select position by index (works on older MT5 builds)        |
//+------------------------------------------------------------------+
bool SelectPositionByIndex(const int index)
{
   ulong ticket = PositionGetTicket(index);
   if(ticket == 0) return false;
   return PositionSelectByTicket(ticket);
}

//+------------------------------------------------------------------+
//| Utility: count positions for this symbol+magic                   |
//+------------------------------------------------------------------+
int CountMyPositions(const string sym)
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectPositionByIndex(i)) continue;
      string psym = PositionGetString(POSITION_SYMBOL);
      long mg     = (long)PositionGetInteger(POSITION_MAGIC);
      if(psym == sym && mg == InpMagic) cnt++;
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| Utility: compute risk-based lots from SL distance                |
//| slDistPrice = absolute price distance between entry and SL       |
//+------------------------------------------------------------------+
double CalcRiskLots(const string sym, double slDistPrice)
{
   if(slDistPrice <= 0) return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPercent / 100.0);

   // money per 1.0 price unit per 1 lot = tick_value / tick_size
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return 0.0;

   double valuePerPriceUnitPerLot = tickValue / tickSize;
   double riskPerLot = slDistPrice * valuePerPriceUnitPerLot;
   if(riskPerLot <= 0) return 0.0;

   double lots = riskMoney / riskPerLot;
   return NormalizeVolume(sym, lots);
}

//+------------------------------------------------------------------+
//| Utility: place market order                                      |
//+------------------------------------------------------------------+
bool OpenTrade(const string sym, const bool isBuy, const double lots, const double sl, const double tp)
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   bool ok;
   if(isBuy) ok = trade.Buy(lots, sym, 0.0, sl, tp, "XAU Autopilot BUY");
   else      ok = trade.Sell(lots, sym, 0.0, sl, tp, "XAU Autopilot SELL");

   if(!ok)
      Print("Order failed. Retcode=", trade.ResultRetcode(), " Desc=", trade.ResultRetcodeDescription());

   return ok;
}

//+------------------------------------------------------------------+
//| Manage trailing and break-even                                   |
//+------------------------------------------------------------------+
void ManagePosition(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectPositionByIndex(i)) continue;

      string psym = PositionGetString(POSITION_SYMBOL);
      long mg     = (long)PositionGetInteger(POSITION_MAGIC);
      if(psym != sym || mg != InpMagic) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);

      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

      // ATR (use last closed bar)
      double atr;
      if(!GetIndVal(hATR, 1, atr)) return;

      // Define R based on SL distance (if no SL, skip)
      if(sl <= 0) continue;
      double R = MathAbs(entry - sl);
      if(R <= 0) continue;

      double priceNow   = (type == POSITION_TYPE_BUY ? bid : ask);
      double profitDist = (type == POSITION_TYPE_BUY ? (priceNow - entry) : (entry - priceNow));

      // Break-even
      if(InpUseBreakEven && profitDist >= InpBE_AtR * R)
      {
         double newSL = entry;

         if(type == POSITION_TYPE_BUY && (sl < newSL))
            trade.PositionModify(sym, newSL, tp);

         if(type == POSITION_TYPE_SELL && (sl > newSL))
            trade.PositionModify(sym, newSL, tp);
      }

      // ATR trailing
      if(InpUseATRTrail && profitDist >= InpTrailStartR * R)
      {
         double trailDist = atr * InpTrail_ATR_Mult;
         double newSL = sl;

         if(type == POSITION_TYPE_BUY)
         {
            double candidate = bid - trailDist;
            if(candidate > newSL) newSL = candidate;
         }
         else
         {
            double candidate = ask + trailDist;
            if(candidate < newSL) newSL = candidate;
         }

         if(MathAbs(newSL - sl) > (SymbolInfoDouble(sym, SYMBOL_POINT) * 2))
         {
            if(!trade.PositionModify(sym, newSL, tp))
               Print("Modify failed. Retcode=", trade.ResultRetcode(), " Desc=", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Optional Donchian exit (opposite breakout)                        |
//+------------------------------------------------------------------+
void DonchianExit(const string sym)
{
   if(InpExitLen < 2) return;

   double upper, lower;
   if(!GetDonchian(sym, InpTF, InpExitLen, upper, lower)) return;

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!SelectPositionByIndex(i)) continue;

      string psym = PositionGetString(POSITION_SYMBOL);
      long mg     = (long)PositionGetInteger(POSITION_MAGIC);
      if(psym != sym || mg != InpMagic) continue;

      long type = PositionGetInteger(POSITION_TYPE);

      if(type == POSITION_TYPE_BUY)
      {
         if(bid < lower) trade.PositionClose(sym);
      }
      else
      {
         if(ask > upper) trade.PositionClose(sym);
      }
   }
}

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   string sym = InpSymbol;

   if(!SymbolSelect(sym, true))
   {
      Print("Failed to select symbol: ", sym);
      return INIT_FAILED;
   }

   hATR = iATR(sym, InpTF, InpATRPeriod);
   if(hATR == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return INIT_FAILED;
   }

   hEMA = iMA(sym, InpTrendTF, InpEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(hEMA == INVALID_HANDLE)
   {
      Print("Failed to create EMA handle");
      return INIT_FAILED;
   }

   hRSI = iRSI(sym, InpTF, InpRSIPeriod, PRICE_CLOSE);
   if(hRSI == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   if(hEMA != INVALID_HANDLE) IndicatorRelease(hEMA);
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
}

//+------------------------------------------------------------------+
//| Main tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   string sym = InpSymbol;

   // Always manage open positions
   ManagePosition(sym);
   DonchianExit(sym);

   if(!SessionOK()) return;
   if(!SpreadOK(sym)) return;

   // New-bar logic on signal timeframe
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(sym, InpTF, 0, 3, r) < 3) return;

   datetime barTime = r[0].time;
   if(barTime == lastBarTime) return;
   lastBarTime = barTime;

   // One trade at a time (optional)
   if(InpOneTradeAtATime && CountMyPositions(sym) > 0) return;

   // Indicators on last closed bar (shift 1)
   double atr, ema, rsi;
   if(!GetIndVal(hATR, 1, atr)) return;
   if(!GetIndVal(hEMA, 1, ema)) return;
   if(!GetIndVal(hRSI, 1, rsi)) return;

   // Donchian breakout levels (exclude current bar)
   double upper, lower;
   if(!GetDonchian(sym, InpTF, InpDonchianLen, upper, lower)) return;

   double close1 = r[1].close;

   // Trend regime
   bool trendUp = (close1 > ema);
   bool trendDn = (close1 < ema);

   // Entry triggers (close breaks channel)
   bool buySignal  = (close1 > upper) && trendUp && (rsi >= InpRSI_BuyMin);
   bool sellSignal = (close1 < lower) && trendDn && (rsi <= InpRSI_SellMax);

   if(!buySignal && !sellSignal) return;

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

   bool isBuy = buySignal;
   double entryPrice = isBuy ? ask : bid;

   double slDist = atr * InpSL_ATR_Mult;
   if(slDist <= 0) return;

   double sl = isBuy ? (entryPrice - slDist) : (entryPrice + slDist);

   // TP in R-multiple
   double tp = 0.0;
   if(InpUseTP)
   {
      double tpDist = (InpTP_R_Mult * slDist);
      tp = isBuy ? (entryPrice + tpDist) : (entryPrice - tpDist);
   }

   // Lot sizing
   double lots = InpFixedLot;
   if(InpRiskBasedLot)
      lots = CalcRiskLots(sym, MathAbs(entryPrice - sl));

   if(lots <= 0) return;

   OpenTrade(sym, isBuy, lots, sl, tp);
}
//+------------------------------------------------------------------+