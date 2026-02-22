//+------------------------------------------------------------------+
//| Boom 500 Time-Close EA (HEDGING: OPEN MANY AT START + TP)         |
//| Opens N positions immediately at start (same tick)                |
//| Dynamic SL from market level (PERIOD_CURRENT) + TP (RR-based)     |
//| Trailing SL (tighten only) + optional time close                  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

// -------------------- Inputs (Parameters) -------------------------
enum TradeDirection
{
   DIR_BUY = 0,
   DIR_SELL = 1
};

input TradeDirection Direction        = DIR_SELL;          // Buy/Sell
input string        TargetSymbol      = "Boom 500 Index";  // Exact Market Watch name
input double        LotSize           = 0.10;              // Lot size per position
input int           PositionsToOpen   = 2;                 // Number of positions to open immediately
input double        MarginSafetyPct   = 10.0;              // Keep % of free margin as buffer
input ulong         MagicNumber       = 5002026;           // EA identifier

input bool          OneShot           = true;              // If true: open once, then never open again
input int           TimerSeconds      = 2;                 // Timer frequency
input int           CloseAfterMinutes = 1;                 // Time-based close (minutes); set 0 to disable

// --- Dynamic Stop Loss (Market Level) on PERIOD_CURRENT ------------
input bool   UseDynamicSL    = true;
input int    SL_LookbackBars = 20;
input int    SL_BufferPoints = 100;
input bool   UseTrailingSL   = true;

// --- Take Profit ---------------------------------------------------
input bool   UseTakeProfit   = true;
input double RiskReward      = 2.0;     // TP distance = risk * RR (risk from SL)

// --- Order send robustness ----------------------------------------
input int    MaxSendRetries       = 5;     // retries per position
input int    RetryDelayMs         = 250;   // delay between retries
input int    DeviationPoints      = 50;    // max price deviation (points)

// -------------------- Internal state ------------------------------
string g_symbol = "";
bool   g_done_once = false;
bool   g_opened_on_start = false;

// -------------------- Helpers -------------------------------------
bool EnsureSymbolSelected(const string sym)
{
   if(!SymbolSelect(sym, true))
   {
      Print("Cannot select symbol: ", sym);
      return false;
   }
   return true;
}

bool IsHedgingAccount()
{
   return (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

// Count open positions for THIS EA on symbol (hedging-safe count)
int CountMyPositions(const string sym)
{
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if((string)PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      count++;
   }
   return count;
}

// Find the FIRST open position for THIS EA on symbol (used for timed close logic)
bool GetMyFirstPosition(const string sym, ulong &ticket, datetime &pos_time)
{
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if((string)PositionGetString(POSITION_SYMBOL) != sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ticket   = t;
      pos_time = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
   }
   return false;
}

// Validate & normalize lots to broker rules for the symbol
double NormalizeLots(const string sym, double requested)
{
   double vmin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double lots = requested;
   if(lots < vmin) lots = vmin;
   if(lots > vmax) lots = vmax;
   if(vstep > 0) lots = MathFloor(lots / vstep) * vstep;

   return NormalizeDouble(lots, 2);
}

// Normalize price to symbol digits
double NormalizePrice(const string sym, double price)
{
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

// Compute margin needed for 1 position, and max positions based on current free margin
int CalcMaxPositionsByMargin(const string sym, double lots, TradeDirection dir, double safetyPct, double &margin_one)
{
   margin_one = 0.0;

   double free_margin = AccountInfoDouble(ACCOUNT_FREEMARGIN);
   if(free_margin <= 0) return 0;

   double usable = free_margin * (1.0 - safetyPct/100.0);
   if(usable <= 0) return 0;

   double price = (dir == DIR_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK)
                                   : SymbolInfoDouble(sym, SYMBOL_BID);
   if(price <= 0.0) return 0;

   ENUM_ORDER_TYPE type = (dir == DIR_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(type, sym, lots, price, margin_one))
   {
      Print("OrderCalcMargin failed. Error=", GetLastError());
      return 0;
   }
   if(margin_one <= 0.0) return 0;

   int max_pos = (int)MathFloor(usable / margin_one);
   if(max_pos < 0) max_pos = 0;
   return max_pos;
}

// --- Market level helpers on PERIOD_CURRENT (swing levels) ---------
double GetSwingHigh(const string sym, int lookback)
{
   double highs[];
   ArraySetAsSeries(highs, true);
   if(lookback < 2) lookback = 2;

   int copied = CopyHigh(sym, PERIOD_CURRENT, 1, lookback, highs);
   if(copied <= 0) return 0.0;

   double h = highs[0];
   for(int i=1; i<copied; i++)
      if(highs[i] > h) h = highs[i];
   return h;
}

double GetSwingLow(const string sym, int lookback)
{
   double lows[];
   ArraySetAsSeries(lows, true);
   if(lookback < 2) lookback = 2;

   int copied = CopyLow(sym, PERIOD_CURRENT, 1, lookback, lows);
   if(copied <= 0) return 0.0;

   double l = lows[0];
   for(int i=1; i<copied; i++)
      if(lows[i] < l) l = lows[i];
   return l;
}

// Ensure SL respects broker minimum stop distance
double EnforceStopsLevel(const string sym, TradeDirection dir, double sl)
{
   if(sl <= 0.0) return 0.0;

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int stops_level = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL); // points
   if(stops_level <= 0) return NormalizePrice(sym, sl);

   double min_dist = stops_level * point;
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);

   if(dir == DIR_BUY)
   {
      double max_sl = bid - min_dist;
      if(sl > max_sl) sl = max_sl;
   }
   else
   {
      double min_sl = ask + min_dist;
      if(sl < min_sl) sl = min_sl;
   }
   return NormalizePrice(sym, sl);
}

// Calculate dynamic SL for the CURRENT moment
double CalcDynamicSL()
{
   if(!UseDynamicSL) return 0.0;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double sl = 0.0;

   if(Direction == DIR_BUY)
   {
      double swingLow = GetSwingLow(g_symbol, SL_LookbackBars);
      if(swingLow > 0.0) sl = swingLow - SL_BufferPoints * point;
   }
   else
   {
      double swingHigh = GetSwingHigh(g_symbol, SL_LookbackBars);
      if(swingHigh > 0.0) sl = swingHigh + SL_BufferPoints * point;
   }

   sl = NormalizePrice(g_symbol, sl);
   sl = EnforceStopsLevel(g_symbol, Direction, sl);
   return sl;
}

// Calculate TP based on SL distance and RiskReward
double CalcTakeProfit(double sl)
{
   if(!UseTakeProfit) return 0.0;
   if(sl <= 0.0) return 0.0;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   double entry = (Direction == DIR_BUY ? ask : bid);

   double risk = 0.0;
   double tp   = 0.0;

   if(Direction == DIR_BUY)
   {
      risk = entry - sl;
      if(risk <= 0.0) return 0.0;
      tp = entry + (risk * RiskReward);
   }
   else
   {
      risk = sl - entry;
      if(risk <= 0.0) return 0.0;
      tp = entry - (risk * RiskReward);
   }

   return NormalizePrice(g_symbol, tp);
}

// Send ONE order with retries (no delays between positions)
bool SendOneOrder()
{
   trade.SetExpertMagicNumber((long)MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   trade.SetTypeFillingBySymbol(g_symbol);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("Terminal trade not allowed.");
      return false;
   }

   long trade_mode = SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE);
   if(trade_mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("Trading disabled for symbol: ", g_symbol);
      return false;
   }

   double lots = NormalizeLots(g_symbol, LotSize);

   // refresh tick
   MqlTick tick;
   if(!SymbolInfoTick(g_symbol, tick))
   {
      Print("SymbolInfoTick failed. Err=", GetLastError());
      return false;
   }

   // compute SL/TP for this moment
   double sl = CalcDynamicSL();
   double tp = CalcTakeProfit(sl);

   for(int attempt=1; attempt<=MaxSendRetries; attempt++)
   {
      bool ok=false;

      if(Direction == DIR_BUY)
         ok = trade.Buy(lots, g_symbol, 0.0, sl, tp);
      else
         ok = trade.Sell(lots, g_symbol, 0.0, sl, tp);

      if(ok)
      {
         Print("Order OK. attempt=", attempt,
               " Lots=", DoubleToString(lots,2),
               " SL=", DoubleToString(sl, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
               " TP=", DoubleToString(tp, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
               " Deal=", trade.ResultDeal(),
               " Order=", trade.ResultOrder());
         return true;
      }

      Print("Order FAILED. attempt=", attempt,
            " Retcode=", trade.ResultRetcode(),
            " ", trade.ResultRetcodeDescription(),
            " SL=", DoubleToString(sl, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)),
            " TP=", DoubleToString(tp, (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS)));

      Sleep(RetryDelayMs);

      // refresh tick and recalc SL/TP before retry
      SymbolInfoTick(g_symbol, tick);
      sl = CalcDynamicSL();
      tp = CalcTakeProfit(sl);
   }

   return false;
}

// Close all positions for this EA on this symbol
void CloseAllMyPositions(const string sym)
{
   trade.SetExpertMagicNumber((long)MagicNumber);

   for(int pass=0; pass<50; pass++)
   {
      bool closed_any=false;

      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(!PositionSelectByTicket(t)) continue;

         if((string)PositionGetString(POSITION_SYMBOL) != sym) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

         if(trade.PositionClose(t))
            closed_any=true;
      }
      if(!closed_any) break;
   }
}

// Tighten dynamic SL over time (never loosen). TP stays fixed.
void UpdateTrailingMarketSL()
{
   if(!UseDynamicSL || !UseTrailingSL) return;

   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if((string)PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long type = (long)PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);

      if(type == POSITION_TYPE_BUY)
      {
         double swingLow = GetSwingLow(g_symbol, SL_LookbackBars);
         if(swingLow <= 0.0) continue;

         double newSL = swingLow - SL_BufferPoints * point;
         newSL = NormalizePrice(g_symbol, newSL);
         newSL = EnforceStopsLevel(g_symbol, DIR_BUY, newSL);

         if(curSL == 0.0 || newSL > curSL)
         {
            double tp = PositionGetDouble(POSITION_TP);
            trade.SetExpertMagicNumber((long)MagicNumber);
            trade.PositionModify(t, newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double swingHigh = GetSwingHigh(g_symbol, SL_LookbackBars);
         if(swingHigh <= 0.0) continue;

         double newSL = swingHigh + SL_BufferPoints * point;
         newSL = NormalizePrice(g_symbol, newSL);
         newSL = EnforceStopsLevel(g_symbol, DIR_SELL, newSL);

         if(curSL == 0.0 || newSL < curSL)
         {
            double tp = PositionGetDouble(POSITION_TP);
            trade.SetExpertMagicNumber((long)MagicNumber);
            trade.PositionModify(t, newSL, tp);
         }
      }
   }
}

// -------------------- EA Events -----------------------------------
int OnInit()
{
   g_symbol = TargetSymbol;
   if(StringLen(g_symbol) <= 0) g_symbol = _Symbol;

   if(!EnsureSymbolSelected(g_symbol))
      return INIT_FAILED;

   Print("ACCOUNT_MARGIN_MODE=", AccountInfoInteger(ACCOUNT_MARGIN_MODE),
         " (Hedging expected = ", (long)ACCOUNT_MARGIN_MODE_RETAIL_HEDGING, ")");

   if(!IsHedgingAccount())
      Alert("Warning: account is not hedging. Multiple positions per symbol may not work.");

   // upfront margin capacity check
   double lots = NormalizeLots(g_symbol, LotSize);
   double margin_one = 0.0;
   int max_pos = CalcMaxPositionsByMargin(g_symbol, lots, Direction, MarginSafetyPct, margin_one);

   Print("EA init: FreeMargin=", DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN), 2),
         " Margin/pos=", DoubleToString(margin_one, 2),
         " MaxPositions=", max_pos,
         " Requested=", PositionsToOpen);

   if(PositionsToOpen <= 0) return INIT_FAILED;
   if(max_pos <= 0) return INIT_FAILED;

   if(PositionsToOpen > max_pos)
   {
      Alert("ERROR: Requested positions exceed margin capacity. MaxPositions=",
            (string)max_pos, " Margin/pos=", DoubleToString(margin_one, 2));
      return INIT_FAILED;
   }

   EventSetTimer(TimerSeconds);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

// Open ALL required positions immediately when EA starts (first tick)
void OnTick()
{
   // only do the bulk-open once
   if(OneShot && g_done_once) return;
   if(g_opened_on_start) return;

   int current = CountMyPositions(g_symbol);
   int to_open = PositionsToOpen - current;
   if(to_open <= 0)
   {
      g_opened_on_start = true;
      if(OneShot) g_done_once = true;
      return;
   }

   // Open multiple positions NOW (same tick), without spacing
   for(int k=0; k<to_open; k++)
   {
      // check margin each loop (margin changes after each order)
      double lots = NormalizeLots(g_symbol, LotSize);
      double margin_one = 0.0;
      int max_pos = CalcMaxPositionsByMargin(g_symbol, lots, Direction, MarginSafetyPct, margin_one);
      int cur = CountMyPositions(g_symbol);

      if(cur >= max_pos)
      {
         Print("ERROR: Margin limit reached while bulk-opening. Current=", cur,
               " MaxByMargin=", max_pos,
               " Margin/pos=", DoubleToString(margin_one,2));
         break;
      }

      if(!SendOneOrder())
         break;
   }

   g_opened_on_start = true;
   if(OneShot) g_done_once = true;
}

void OnTimer()
{
   // 1) trailing SL
   UpdateTrailingMarketSL();

   // 2) time close
   if(CloseAfterMinutes <= 0) return;

   ulong ticket=0;
   datetime pos_time=0;

   if(GetMyFirstPosition(g_symbol, ticket, pos_time))
   {
      datetime now = TimeTradeServer();
      if((now - pos_time) >= (long)CloseAfterMinutes * 60)
      {
         Print("Time exit triggered. Closing all EA positions.");
         CloseAllMyPositions(g_symbol);
      }
   }
}
//+------------------------------------------------------------------+