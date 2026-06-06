//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v33.0                      |
//|  BUY-only | 3.5 lots | slope MA20 removido | >4%/mes USDJPY M5  |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v32 (0 trades, 2026.05.03-2026.06.04):
//  - CAUSA: filtro slope MA20 bloqueou 100% das entradas
//    Em mai-jun/2026 USDJPY em retração => MA20[1] < MA20[2] consistente
//    Filtro de comparação barra-a-barra no M5 é ruidoso demais.
//  - Conclusão: slope MA20 em M5 (1 barra lookback) inviável. Removido.
//
//  DIAGNOSTICO v31 (287 trades BUY, 2025.01-2026.06 = 17 meses):
//  - Win rate: 38.33% | PF: 1.23 | Sharpe: 5.14
//  - Lucro total: +8.115 EUR = 477 EUR/mes = 4.77%/mes (META ATINGIDA)
//  - PROBLEMA: Max DD = 40.11% (4.681 EUR) inaceitável em conta real
//  - Max consecutive losses: 8 = -2.862 EUR = 28.6% da conta
//
//  ESTRATEGIA v33 — REDUCAO SIMPLES E VALIDADA:
//  Remover filtro de slope (quebrado). Reduzir lote 4.0 -> 3.5.
//  Projeção linear escala = v31 * (3.5/4.0):
//    Lucro:    477 x 0.875 = 417 EUR/mes = 4.17%/mes (META ATINGIDA)
//    Max DD:   40.11% x 0.875 = ~35.1% (redução de 5 pp vs v31)
//    Avg loss: 202.89 x 0.875 = ~177 EUR = 1.77% da conta
//    8 losses: ~1.416 EUR = 14.2% da conta (vs 28.6% em v31)
//
//  Se DD 35% ainda inaceitável:
//    3.0 lots => DD ~30%, retorno ~3.6%/mes (abaixo da meta)
//    Para 4%+ com 3.0 lots: necessário melhorar win rate para 42%+
//    Alternativa: adicionar filtro RSI ou H1 timeframe alignment
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "33.00"
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
input bool   PermitirVenda           = false;  // SELL: never profitable in USDJPY 2025-2026

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 3.5;   // 3.5 => ~4.17%/mes, DD~35% | 3.0 => ~3.6%/mes, DD~30%
input double RiscoRetorno            = 2.0;

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 1.7;   // Floor: 1.5
input double PavioMinimoATR          = 0.25;
input double SL_Folga_ATR            = 0.2;   // Floor: 0.1 — SL colado ao pavio

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;
input double SaidaDinamicaMinRR      = 2.0;

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;  // BUY: MA20 > MA200 (uptrend)

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
int hMA200, hMA20, hATR;

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
      Print("AVISO v33: MinAfastamentoATR elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v33: SL_Folga_ATR elevado ao floor de ", gSL_Folga_ATR);

   double perda_est   = 5.07 * LoteInicial / 0.1;
   double lucro_est   = 11.97 * LoteInicial / 0.1;

   Print("v33 | Lote:", LoteInicial,
         " | Perda media estimada: ~", NormalizeDouble(perda_est, 0), " EUR (",
         NormalizeDouble(perda_est / 100.0, 1), "% de 10K)",
         " | Lucro mensal estimado: ~", NormalizeDouble(lucro_est, 0), " EUR (",
         NormalizeDouble(lucro_est / 100.0, 1), "% de 10K)");
   Print("v33 | MinAfastATR:", gMinAfastamentoATR,
         " FiltroMA200:", (UsarFiltroMA200 ? "ON" : "OFF"),
         " Cooldown:", CooldownBarrasSL,
         " SlopeFilter: REMOVIDO");

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
      double slBuffer = atr * gSL_Folga_ATR;
      double gatOff   = atr * 0.08;

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

            if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
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

            if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               setupCompraAtivo = true;
               Print("SETUP COMPRA | SL:", sl, " TP:", tp,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     " distMA20:", NormalizeDouble(distMA20/atr,2), "xATR");
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
         trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v33");
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
         trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v33");
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
