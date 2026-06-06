//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v28.0                      |
//|  MERGE: filtro MA200 (v13) + ATR-adaptativo (v27)               |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v27 (54 trades, 2025.01-2026.06):
//  - Win rate: 27.78% | R:R: 1.50 | PF: 0.58 | Perda: -257 EUR
//  - Problema 1: MinAfastATR=3.5 gerou so 54 trades (3.2/mes) — sem volume
//  - Problema 2: UsarFiltroMA200=false — BUY tomado contra a tendencia
//  - Max losses consecutivas: 19 (-278 EUR) — sem cooldown = cascata
//
//  DIAGNOSTICO v13 (1 mes, backtest curto):
//  - Win rate BUY: 54%  |  win rate SELL: 33%  |  Resultado: +$91
//  - CHAVE DO SUCESSO: UsarFiltroMA200=true
//    BUY so quando MA20 > MA200 (uptrend confirmado)
//    SELL so quando MA20 < MA200 (downtrend confirmado)
//  - Em USDJPY 2025-2026 (JPY fraco): MA20 > MA200 quase todo o tempo
//    => BUY ativo, SELL bloqueado automaticamente pela tendencia
//
//  CAUSA RAIZ DOS PROBLEMAS (v24-v27):
//  Com UsarFiltroMA200=false, o EA comprava em correcoes de downtrend
//  (MA20 < MA200) e vendia em correcoes de uptrend (MA20 > MA200).
//  Ambos sao contra a tendencia dominante = win rate baixo.
//
//  CORRECOES v28 (MERGE v13 + v27):
//  [1] UsarFiltroMA200 = true   => PRINCIPAL: alinha com tendencia
//      BUY: MA20 > MA200 | SELL: MA20 < MA200
//  [2] PermitirVenda = true     => MA200 controla direcao dinamicamente
//      (nao hardcoded — adapta quando USDJPY mudar de regime)
//  [3] MinAfastamentoATR = 2.0  => restaurado (3.5 era restritivo demais)
//  [4] CooldownBarrasSL = 6     => evita cascata de losses (19 consec. v27)
//  [5] Mantido: sem BreakEven, ATR-adaptativo, SaidaDinamica, anti-gap
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "28.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//==================================================================
//  INPUTS
//==================================================================

input group "=== DIRECOES ==="
input bool   PermitirCompra          = true;
input bool   PermitirVenda           = true;   // MA200 controla direcao

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 0.1;
input double RiscoRetorno            = 2.0;   // Multiplo TP/SL (0 = sem TP fixo)

input group "=== THRESHOLDS EM ATR (multi-ativo / multi-TF) ==="
input double MinAfastamentoATR       = 2.0;   // Distancia minima da MA20 em ATR (floor: 2.0)
input double PavioMinimoATR          = 0.25;  // Pavio minimo do candle de sinal
input double SL_Folga_ATR            = 1.0;   // Buffer SL alem do extremo do pavio (floor: 0.8)

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;    // Barras minimas antes de checar saida
input double SaidaDinamicaMinRR      = 2.0;   // Lucro minimo (x risco) antes de fechar

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;  // [v13] BUY: MA20>MA200 | SELL: MA20<MA200

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== FILTRO DE HORARIO ==="
input bool   UsarFiltroHorario       = true;
input int    HoraInicio              = 7;
input int    HoraFim                 = 21;

input group "=== COOLDOWN POS-SL ==="
input int    CooldownBarrasSL        = 6;     // [v13] Barras de pausa apos SL (0=desativado)

input group "=== GERAL ==="
input ulong  MagicNumber             = 202409;

//==================================================================
//  HANDLES
//==================================================================
int hMA200, hMA20, hATR;

//==================================================================
//  VALORES EFETIVOS COM FLOORS OBRIGATORIOS
//==================================================================
double gMinAfastamentoATR;  // floor: 2.0
double gSL_Folga_ATR;       // floor: 0.8

//==================================================================
//  ESTADO PERSISTENTE
//==================================================================
datetime lastBar        = 0;

bool   setupCompraAtivo  = false;
bool   setupVendaAtivo   = false;
double precoGatilho      = 0.0;
double precoStopLoss     = 0.0;
double precoTakeProfit   = 0.0;
double lastATR           = 0.0;

int    cooldownCompra    = 0;
int    cooldownVenda     = 0;


//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   gMinAfastamentoATR = MathMax(MinAfastamentoATR, 2.0);
   gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.8);

   if(gMinAfastamentoATR != MinAfastamentoATR)
      Print("AVISO v28: MinAfastamentoATR ", MinAfastamentoATR,
            " elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v28: SL_Folga_ATR ", SL_Folga_ATR,
            " elevado ao floor de ", gSL_Folga_ATR);

   Print("v28 parametros efetivos | MinAfastATR:", gMinAfastamentoATR,
         " SL_Folga:", gSL_Folga_ATR,
         " FiltroMA200:", (UsarFiltroMA200 ? "ON" : "OFF"),
         " Cooldown:", CooldownBarrasSL, " barras",
         " BUY:", (PermitirCompra ? "ON" : "OFF"),
         " SELL:", (PermitirVenda  ? "ON" : "OFF"));

   hMA200 = iMA (_Symbol, _Period, MA200_Period, 0, MODE_SMA, PRICE_CLOSE);
   hMA20  = iMA (_Symbol, _Period, MA20_Period,  0, MODE_SMA, PRICE_CLOSE);
   hATR   = iATR(_Symbol, _Period, ATR_Periodo);

   if(hMA200 == INVALID_HANDLE || hMA20 == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("ERRO: falha ao criar handle de indicador.");
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int r)
{
   IndicatorRelease(hMA200);
   IndicatorRelease(hMA20);
   IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime barAtual = iTime(_Symbol, _Period, 0);

   if(barAtual != lastBar)
   {
      lastBar = barAtual;

      // Decrementa cooldowns a cada nova barra
      if(cooldownCompra > 0) cooldownCompra--;
      if(cooldownVenda  > 0) cooldownVenda--;

      setupCompraAtivo = false;
      setupVendaAtivo  = false;

      if(HasPosition())
      {
         if(UsarSaidaDinamica) VerificarSaidaDinamica();
         return;
      }

      if(UsarFiltroHorario)
      {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         if(dt.hour < HoraInicio || dt.hour >= HoraFim) return;
      }

      double ma20  = GetBuffer(hMA20,  1);
      double ma200 = GetBuffer(hMA200, 1);
      double atr   = GetBuffer(hATR,   1);
      if(ma20 <= 0 || atr <= 0) return;
      if(UsarFiltroMA200 && ma200 <= 0) return;

      double C1 = iClose(_Symbol, _Period, 1);
      double H1 = iHigh (_Symbol, _Period, 1);
      double L1 = iLow  (_Symbol, _Period, 1);
      double O1 = iOpen (_Symbol, _Period, 1);
      double H2 = iHigh (_Symbol, _Period, 2);
      double L2 = iLow  (_Symbol, _Period, 2);

      double distMA20 = MathAbs(C1 - ma20);
      double distMin  = atr * gMinAfastamentoATR;
      double pavioMin = atr * PavioMinimoATR;
      double slBuffer = atr * gSL_Folga_ATR;
      double gatOff   = atr * 0.08;

      lastATR = atr;

      bool sell_cond = (H1 > H2 && C1 <= H2);
      bool buy_cond  = (L1 < L2 && C1 >= L2);

      bool ok_padrao_venda  = sell_cond && (!buy_cond  || C1 < O1);
      bool ok_padrao_compra = buy_cond  && (!sell_cond || C1 > O1);

      //------------------------------------------------------------
      // SETUP DE VENDA - Falha de Topo
      //------------------------------------------------------------
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200  = !UsarFiltroMA200 || (ma20 < ma200); // SELL: MA20 < MA200 (downtrend)
         bool ok_pavio  = (pavioSup >= pavioMin);
         bool ok_cd     = (cooldownVenda == 0);

         if(ok_MA200 && ok_pavio && ok_padrao_venda && ok_cd)
         {
            double gatilho = L1 - gatOff;
            double sl      = NormalizeDouble(H1 + slBuffer, _Digits);
            double risco   = sl - gatilho;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho - risco * RiscoRetorno, _Digits)
                             : 0.0;

            if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               precoTakeProfit = tp;
               setupVendaAtivo = true;
               Print("SETUP VENDA | L1:", L1, " H1:", H1, " H2:", H2,
                     " SL:", sl, " TP:", tp, " ATR:", atr,
                     " MA20:", NormalizeDouble(ma20,3), " MA200:", NormalizeDouble(ma200,3));
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200  = !UsarFiltroMA200 || (ma20 > ma200); // BUY: MA20 > MA200 (uptrend)
         bool ok_pavio  = (pavioInf >= pavioMin);
         bool ok_cd     = (cooldownCompra == 0);

         if(ok_MA200 && ok_pavio && ok_padrao_compra && ok_cd)
         {
            double gatilho = H1 + gatOff;
            double sl      = NormalizeDouble(L1 - slBuffer, _Digits);
            double risco   = gatilho - sl;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                             : 0.0;

            if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               setupCompraAtivo = true;
               Print("SETUP COMPRA | H1:", H1, " L1:", L1, " L2:", L2,
                     " SL:", sl, " TP:", tp, " ATR:", atr,
                     " MA20:", NormalizeDouble(ma20,3), " MA200:", NormalizeDouble(ma200,3));
            }
         }
      }
   }

   if(HasPosition()) return;

   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double maxGap = (lastATR > 0) ? lastATR * 0.5 : 0.0;

   if(setupCompraAtivo && ask >= precoGatilho)
   {
      double overshoot = ask - precoGatilho;
      if(maxGap <= 0 || overshoot <= maxGap)
      {
         trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v28");
         Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss, " TP:", precoTakeProfit);
      }
      else
         Print("COMPRA cancelada (anti-gap): ", DoubleToString(overshoot/lastATR,2), "xATR");
      setupCompraAtivo = false;
   }

   if(setupVendaAtivo && bid <= precoGatilho)
   {
      double overshoot = precoGatilho - bid;
      if(maxGap <= 0 || overshoot <= maxGap)
      {
         trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v28");
         Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss, " TP:", precoTakeProfit);
      }
      else
         Print("VENDA cancelada (anti-gap): ", DoubleToString(overshoot/lastATR,2), "xATR");
      setupVendaAtivo = false;
   }
}

//+------------------------------------------------------------------+
void VerificarSaidaDinamica()
{
   double C1     = iClose(_Symbol, _Period, 1);
   double H2     = iHigh (_Symbol, _Period, 2);
   double L2     = iLow  (_Symbol, _Period, 2);
   long   segBar = (long)PeriodSeconds();
   if(segBar <= 0) segBar = 300;

   datetime barAbertura = iTime(_Symbol, _Period, 0);
   double   bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double   ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      datetime openTime    = (datetime)PositionGetInteger(POSITION_TIME);
      long     barrasDecor = (long)(barAbertura - openTime) / segBar;
      if(barrasDecor < MinBarrasHold) continue;

      ENUM_POSITION_TYPE tipo      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             abertura  = PositionGetDouble(POSITION_PRICE_OPEN);
      double             slPos     = PositionGetDouble(POSITION_SL);
      double             riscoPreco = MathAbs(slPos - abertura);

      double lucroPreco = (tipo == POSITION_TYPE_SELL)
                          ? abertura - ask
                          : bid - abertura;

      if(lucroPreco < riscoPreco * SaidaDinamicaMinRR) continue;

      if(tipo == POSITION_TYPE_SELL && C1 > H2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA VENDA (din) C[1]:", C1, " > H[2]:", H2,
               " RR:", (riscoPreco > 0 ? lucroPreco/riscoPreco : 0));
      }
      else if(tipo == POSITION_TYPE_BUY && C1 < L2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA COMPRA (din) C[1]:", C1, " < L[2]:", L2,
               " RR:", (riscoPreco > 0 ? lucroPreco/riscoPreco : 0));
      }
   }
}

//+------------------------------------------------------------------+
// Detecta SL e ativa cooldown direcional
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(CooldownBarrasSL <= 0) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal))           return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)MagicNumber) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   if(profit >= 0.0) return; // Apenas SL (nao TP)

   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(tipo == DEAL_TYPE_BUY) // Fechou posicao SHORT com prejuizo = SL em SELL
   {
      cooldownVenda = CooldownBarrasSL;
      Print("COOLDOWN VENDA ativado: ", CooldownBarrasSL, " barras");
   }
   else if(tipo == DEAL_TYPE_SELL) // Fechou posicao LONG com prejuizo = SL em BUY
   {
      cooldownCompra = CooldownBarrasSL;
      Print("COOLDOWN COMPRA ativado: ", CooldownBarrasSL, " barras");
   }
}

//+------------------------------------------------------------------+
bool ValidarStops(double gatilho, double sl, ENUM_ORDER_TYPE tipo)
{
   long   nivelPts   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double nivelPreco = nivelPts * _Point;
   if(nivelPreco <= 0) return true;

   double preco  = (tipo == ORDER_TYPE_BUY)
                   ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                   : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distSL = MathAbs(preco - sl);

   if(distSL < nivelPreco)
   {
      Print("Setup ignorado: SL a ", distSL/_Point, " pts (min:", nivelPts, ")");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
double GetBuffer(int handle, int idx)
{
   double buf[1];
   if(CopyBuffer(handle, 0, idx, 1, buf) > 0) return buf[0];
   return 0.0;
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC)  == (long)MagicNumber)
            return true;
   }
   return false;
}
