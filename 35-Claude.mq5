//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v35.0                      |
//|  Filtro regime volatilidade | 3.5 lots | USDJPY M5               |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v34 out-of-sample 2022-2024 (313 trades):
//  - Win rate: 34.50% | PF: 0.86 | Sharpe: -5.00
//  - Lucro: -6.807 EUR | Max DD: 75.92% (destruiria conta)
//  - Max 19 losses consecutivos = -6.692 EUR
//  - Causa: 2022-2024 teve periodos de alta volatilidade extrema
//    (intervencoes BOJ, movimentos violentos USD) que geraram sinais
//    falsos de reversao. A estrategia entrou em setups tecnicamente
//    validos mas que continuaram tendendo ao inves de reverter.
//
//  SOLUCAO v35 — FILTRO DE REGIME DE VOLATILIDADE:
//  Novo input MaxRazaoATR = 1.8:
//    Compara ATR(14) atual com ATR(100) como baseline de longo prazo.
//    Se ATR(14) / ATR(100) > 1.8 => mercado em regime de alta
//    volatilidade => pular barra, nao montar setup.
//
//  LOGICA DO FILTRO:
//    Normal:     ATR(14) ≈ ATR(100) => razao ≈ 1.0 => opera
//    Volatil:    ATR(14) = 1.5x ATR(100) => razao 1.5 => opera
//    Crise/BOJ:  ATR(14) = 2x+ ATR(100) => razao 2.0 => BLOQUEIA
//    Threshold 1.8: bloqueia spikes extremos, preserva volatilidade normal
//
//  IMPACTO ESPERADO:
//    - Bloqueia periodos de intervencao BOJ e crises de 2022-2024
//    - Pode reduzir 10-20% dos trades em periodos normais
//    - Win rate deve melhorar pois exclui setups em mercado caótico
//    - MaxRazaoATR=0 desabilita o filtro (modo v34)
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "35.00"
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
input bool   PermitirVenda           = false;

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 3.5;
input double RiscoRetorno            = 2.0;

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 1.7;
input double PavioMinimoATR          = 0.25;
input double SL_Folga_ATR            = 0.2;
input double MaxSLDistanciaATR       = 2.5;   // 0 = desabilitado

input group "=== FILTRO DE REGIME DE VOLATILIDADE ==="
input bool   UsarFiltroVolatilidade  = true;
input int    ATR_Longo_Periodo       = 100;   // ATR baseline de longo prazo
input double MaxRazaoATR             = 1.8;   // Bloqueia se ATR(14)/ATR(100) > 1.8
                                               // 0 = desabilitado
                                               // 1.8: permite volatilidade moderada,
                                               //      bloqueia spikes de crise/intervencao

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;
input double SaidaDinamicaMinRR      = 2.0;

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== FILTRO DE HORARIO ==="
input bool   UsarFiltroHorario       = true;
input int    HoraInicio              = 7;
input int    HoraFim                 = 21;

input group "=== COOLDOWN POS-SL ==="
input int    CooldownBarrasSL        = 3;

input group "=== GERAL ==="
input ulong  MagicNumber             = 202409;

//==================================================================
//  HANDLES
//==================================================================
int hMA200, hMA20, hATR, hATR_Longo;

//==================================================================
//  FLOORS
//==================================================================
double gMinAfastamentoATR;
double gSL_Folga_ATR;

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

   gMinAfastamentoATR = MathMax(MinAfastamentoATR, 1.5);
   gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.1);

   if(gMinAfastamentoATR != MinAfastamentoATR)
      Print("AVISO v35: MinAfastamentoATR elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v35: SL_Folga_ATR elevado ao floor de ", gSL_Folga_ATR);

   Print("v35 | Lote:", LoteInicial,
         " | MaxSLDistATR:", MaxSLDistanciaATR,
         " | FiltroVol:", (UsarFiltroVolatilidade ? "ON" : "OFF"),
         " | MaxRazaoATR:", MaxRazaoATR,
         " | ATR_Longo:", ATR_Longo_Periodo,
         " | FiltroMA200:", (UsarFiltroMA200 ? "ON" : "OFF"));

   hMA200     = iMA  (_Symbol, _Period, MA200_Period,      0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period, MA20_Period,       0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period, ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period, ATR_Longo_Periodo);

   if(hMA200     == INVALID_HANDLE || hMA20  == INVALID_HANDLE ||
      hATR       == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE)
   {
      Print("ERRO v35: falha ao criar handle de indicador.");
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
   IndicatorRelease(hATR_Longo);
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime barAtual = iTime(_Symbol, _Period, 0);

   if(barAtual != lastBar)
   {
      lastBar = barAtual;

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

      double ma20      = GetBuffer(hMA20,      1);
      double ma200     = GetBuffer(hMA200,     1);
      double atr       = GetBuffer(hATR,       1);
      double atr_longo = GetBuffer(hATR_Longo, 1);

      if(ma20 <= 0 || atr <= 0) return;
      if(UsarFiltroMA200 && ma200 <= 0) return;

      // --- FILTRO DE REGIME DE VOLATILIDADE ---
      if(UsarFiltroVolatilidade && MaxRazaoATR > 0 && atr_longo > 0)
      {
         double razao = atr / atr_longo;
         if(razao > MaxRazaoATR)
         {
            Print("REGIME BLOQUEADO: ATR(", ATR_Periodo, ")/ATR(", ATR_Longo_Periodo,
                  ") = ", NormalizeDouble(razao, 2), " > ", MaxRazaoATR,
                  " | ATR=", NormalizeDouble(atr, _Digits),
                  " ATRlongo=", NormalizeDouble(atr_longo, _Digits));
            return;
         }
      }

      double C1 = iClose(_Symbol, _Period, 1);
      double H1 = iHigh (_Symbol, _Period, 1);
      double L1 = iLow  (_Symbol, _Period, 1);
      double O1 = iOpen (_Symbol, _Period, 1);
      double H2 = iHigh (_Symbol, _Period, 2);
      double L2 = iLow  (_Symbol, _Period, 2);

      double distMA20  = MathAbs(C1 - ma20);
      double distMin   = atr * gMinAfastamentoATR;
      double pavioMin  = atr * PavioMinimoATR;
      double slBuffer  = atr * gSL_Folga_ATR;
      double gatOff    = atr * 0.08;
      double maxRisco  = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;

      lastATR = atr;

      bool sell_cond = (H1 > H2 && C1 <= H2);
      bool buy_cond  = (L1 < L2 && C1 >= L2);

      bool ok_padrao_venda  = sell_cond && (!buy_cond  || C1 < O1);
      bool ok_padrao_compra = buy_cond  && (!sell_cond || C1 > O1);

      //------------------------------------------------------------
      // SETUP DE VENDA - Falha de Topo (desabilitado por padrao)
      //------------------------------------------------------------
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200 = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_pavio = (pavioSup >= pavioMin);
         bool ok_cd    = (cooldownVenda == 0);

         if(ok_MA200 && ok_pavio && ok_padrao_venda && ok_cd)
         {
            double gatilho = L1 - gatOff;
            double sl      = NormalizeDouble(H1 + slBuffer, _Digits);
            double risco   = sl - gatilho;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho - risco * RiscoRetorno, _Digits)
                             : 0.0;

            bool ok_sl_dist = (maxRisco <= 0) || (risco <= maxRisco);

            if(!ok_sl_dist)
               Print("VENDA ignorada (SL teto): ", NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               precoTakeProfit = tp;
               setupVendaAtivo = true;
               Print("SETUP VENDA | SL:", sl, " TP:", tp,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR");
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200 = !UsarFiltroMA200 || (ma20 > ma200);
         bool ok_pavio = (pavioInf >= pavioMin);
         bool ok_cd    = (cooldownCompra == 0);

         if(ok_MA200 && ok_pavio && ok_padrao_compra && ok_cd)
         {
            double gatilho = H1 + gatOff;
            double sl      = NormalizeDouble(L1 - slBuffer, _Digits);
            double risco   = gatilho - sl;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                             : 0.0;

            bool ok_sl_dist = (maxRisco <= 0) || (risco <= maxRisco);

            if(!ok_sl_dist)
               Print("COMPRA ignorada (SL teto): ", NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               setupCompraAtivo = true;
               Print("SETUP COMPRA | SL:", sl, " TP:", tp,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     " razaoATR:", NormalizeDouble(atr/(atr_longo>0?atr_longo:atr),2));
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
         trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v35");
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
         trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v35");
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

      ENUM_POSITION_TYPE tipo       = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             abertura   = PositionGetDouble(POSITION_PRICE_OPEN);
      double             slPos      = PositionGetDouble(POSITION_SL);
      double             riscoPreco = MathAbs(slPos - abertura);

      double lucroPreco = (tipo == POSITION_TYPE_SELL)
                          ? abertura - ask
                          : bid - abertura;

      if(lucroPreco < riscoPreco * SaidaDinamicaMinRR) continue;

      if(tipo == POSITION_TYPE_SELL && C1 > H2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA VENDA (din) RR:", (riscoPreco > 0 ? lucroPreco/riscoPreco : 0));
      }
      else if(tipo == POSITION_TYPE_BUY && C1 < L2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA COMPRA (din) RR:", (riscoPreco > 0 ? lucroPreco/riscoPreco : 0));
      }
   }
}

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
   if(profit >= 0.0) return;

   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(tipo == DEAL_TYPE_BUY)
   {
      cooldownVenda = CooldownBarrasSL;
      Print("COOLDOWN VENDA: ", CooldownBarrasSL, " barras");
   }
   else if(tipo == DEAL_TYPE_SELL)
   {
      cooldownCompra = CooldownBarrasSL;
      Print("COOLDOWN COMPRA: ", CooldownBarrasSL, " barras");
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
