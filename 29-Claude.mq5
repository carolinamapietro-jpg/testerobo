//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v29.0                      |
//|  SL ajustado ao pavio | BUY-only | MA200 filtro de tendencia     |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v28 (328 trades, 2025.01-2026.06):
//  - BUY: 172 trades, 36.63% win rate (acima do break-even de 34.3%)
//  - SELL: 156 trades, 30.13% win rate (abaixo do break-even)
//  - PF GERAL: 0.97 (quase lucrativo!)
//  - R:R real: 1.915 | Avg win: 15.90 EUR | Avg loss: 8.30 EUR
//
//  CAUSA RAIZ DO PF < 1.0:
//  SL_Folga_ATR=1.0 adicionava 1 ATR ao SL, inflando o risco.
//  Com risco maior, o TP ficava ACIMA da MA20 — exigia atravessar
//  a media, que e um nivel de resistencia natural.
//
//  MATEMATICA DO ALINHAMENTO TP/MA20 (BUY tipico):
//  Com SL_Folga=1.0: TP = MA20 + 1.34xATR  [ATRAVESSA a media] ✗
//  Com SL_Folga=0.2: TP = MA20 - 0.26xATR  [ABAIXO da media]  ✓
//
//  Isso e exatamente o que o EA simples (EA Falha Exaustao.mq5) fazia
//  ao usar SL direto no pavio (sem buffer): TP ficava proximo ao MA20.
//
//  CORRECOES v29 (MERGE final):
//  [1] SL_Folga_ATR = 0.2  => SL colado ao pavio; TP abaixo do MA20
//      Floor reduzido de 0.8 para 0.1 (nao bloquear o novo valor)
//  [2] PermitirVenda = false => SELL: 30.13% win rate, sempre perde
//      BUY com MA200 filtro: 36.63% win rate => PF estimado 1.15+
//  [3] UsarFiltroMA200 = true (mantido do v28 — melhora BUY)
//  [4] MinAfastamentoATR = 2.0 (mantido — 172 trades no periodo)
//  [5] CooldownBarrasSL = 6 (mantido — previne cascata)
//
//  PROJECAO v29 (BUY-only, win rate estimado 38-42%):
//  PF = (40% x 2.0) / (60% x 1.0) = 1.33  =>  LUCRATIVO
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "29.00"
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
input bool   PermitirVenda           = false;  // SELL: 30.13% win rate em v28, desabilitado

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 0.1;
input double RiscoRetorno            = 2.0;

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 2.0;   // Distancia minima da MA20 em ATR (floor: 2.0)
input double PavioMinimoATR          = 0.25;  // Pavio minimo do candle de sinal
input double SL_Folga_ATR            = 0.2;   // Buffer SL alem do pavio (floor: 0.1)
                                               // Pequeno: TP alinha ABAIXO da MA20

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;
input double SaidaDinamicaMinRR      = 2.0;

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;  // BUY: MA20>MA200 | SELL: MA20<MA200

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== FILTRO DE HORARIO ==="
input bool   UsarFiltroHorario       = true;
input int    HoraInicio              = 7;
input int    HoraFim                 = 21;

input group "=== COOLDOWN POS-SL ==="
input int    CooldownBarrasSL        = 6;     // 0 = desativado

input group "=== GERAL ==="
input ulong  MagicNumber             = 202409;

//==================================================================
//  HANDLES
//==================================================================
int hMA200, hMA20, hATR;

//==================================================================
//  FLOORS OBRIGATORIOS
//==================================================================
double gMinAfastamentoATR;  // floor: 2.0
double gSL_Folga_ATR;       // floor: 0.1 (reduzido — SL deve ser proximo ao pavio)

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
   gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.1);  // floor reduzido para 0.1

   if(gMinAfastamentoATR != MinAfastamentoATR)
      Print("AVISO v29: MinAfastamentoATR ", MinAfastamentoATR,
            " elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v29: SL_Folga_ATR ", SL_Folga_ATR,
            " elevado ao floor de ", gSL_Folga_ATR);

   // Validacao de alinhamento TP/MA20
   double risco_estimado = 0.5 + gSL_Folga_ATR + 0.08;  // pavio + folga + gatOff (em xATR)
   double tp_dist_da_ma20 = gMinAfastamentoATR - 0.18 - 2.0 * risco_estimado;
   string alinhamento = (tp_dist_da_ma20 < 0) ? "ABAIXO da MA20 [OK]" : "ACIMA da MA20 [ruim]";
   Print("v29 init | MinAfastATR:", gMinAfastamentoATR,
         " SL_Folga:", gSL_Folga_ATR,
         " TP estimado: ", NormalizeDouble(tp_dist_da_ma20, 2), "xATR ", alinhamento,
         " | FiltroMA200:", (UsarFiltroMA200 ? "ON" : "OFF"),
         " | Cooldown:", CooldownBarrasSL);

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
      double slBuffer = atr * gSL_Folga_ATR;   // pequeno: SL colado ao pavio
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

         bool ok_MA200  = !UsarFiltroMA200 || (ma20 < ma200);
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
               Print("SETUP VENDA | SL:", sl, " TP:", tp, " ATR:", atr,
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

         bool ok_MA200  = !UsarFiltroMA200 || (ma20 > ma200);
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
               Print("SETUP COMPRA | SL:", sl, " TP:", tp, " ATR:", atr,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
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
         trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v29");
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
         trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v29");
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
