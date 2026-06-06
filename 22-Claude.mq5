//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v22.0                      |
//|  Remove slope filter (bug) | SELL desativado | BUY-only          |
//+------------------------------------------------------------------+
//
//  BUG IDENTIFICADO NO v21:
//
//  O filtro de slope (MA20 subindo para BUY / caindo para SELL) e o
//  filtro de distancia (preco 2xATR da MA20) sao CONTRADITORIOS:
//
//  Para BUY: exigimos preco 2xATR ABAIXO da MA20 (preco caiu muito)
//            mas tambem exigimos MA20 SUBINDO (slope positivo).
//  Problema: quando preco cai 2xATR abaixo da MA20, a propria MA20
//  ja comeou a cair tambem (incorpora as ultimas 20 barras de queda).
//  Resultado: slope negativo => ok_slope=false => BUY rejeitado.
//  Efeito no otimizador: 0 trades em TODAS as 819 combinacoes testadas.
//
//  DIAGNOSTICO v20 (base de comparacao):
//  SELL:  151 trades | 35.10% win rate | perde ~116 EUR/ano
//  BUY:   206 trades | 43.69% win rate | ganha  ~37 EUR/ano
//  NET:   357 trades | -77.18 EUR/ano
//
//  DECISAO v22:
//  [1] Remocao do filtro de slope (causou 0 trades no v21).
//  [2] SELL desativado por padrao (PermitirVenda=false):
//      SELL teve 35.10% win rate vs break-even de 42.05%.
//      BUY teve 43.69% win rate (acima do break-even).
//      Operar so BUY elimina a principal fonte de prejuizo.
//      SELL pode ser reativado manualmente se desejado.
//  [3] Mantidos do v20/v21:
//      - Floors: MinAfastamentoATR>=2.0, SL_Folga>=0.8, BreakEven>=1.5
//      - Protecao anti-gap (0.5xATR)
//      - SaidaDinamicaMinRR, MinBarrasHold=15
//      - Correto gatilho de entrada (ask para BUY, bid para SELL)
//
//  LOGICA DE PADRAO (identica ao v13/v19/v20):
//  BUY:  L1<L2 && C1>=L2 (falha abaixo da minima anterior)
//  SELL: H1>H2 && C1<=H2 (falha acima da maxima anterior)
//  Corpo so e usado para desambiguar outside bars.
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "22.00"
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
input bool   PermitirVenda           = false;  // SELL desativado: win rate 35% vs BE 42%

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
input double SaidaDinamicaMinRR      = 1.0;   // Lucro minimo (x risco) antes de fechar

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;

input group "=== GESTAO DE POSICAO ==="
input bool   UsarBreakEven           = true;
input double BreakEvenATR            = 1.5;   // Lucro (x ATR) para mover SL a entrada (floor: 1.5)

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== GESTAO DE RISCO DIARIA ==="
input int    MaxTradesPorDirecao     = 2;
input int    CooldownBarrasSL        = 12;    // Barras bloqueadas apos SL

input group "=== FILTRO DE HORARIO ==="
input bool   UsarFiltroHorario       = true;
input int    HoraInicio              = 7;
input int    HoraFim                 = 21;

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
double gBreakEvenATR;       // floor: 1.5

//==================================================================
//  ESTADO PERSISTENTE
//==================================================================
datetime lastBar        = 0;
datetime diaAtual       = 0;

bool   setupCompraAtivo  = false;
bool   setupVendaAtivo   = false;
double precoGatilho      = 0.0;
double precoStopLoss     = 0.0;
double precoTakeProfit   = 0.0;
double lastATR           = 0.0;

int    tradesCompraHoje  = 0;
int    tradesVendaHoje   = 0;
int    cooldownCompra    = 0;
int    cooldownVenda     = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   gMinAfastamentoATR = MathMax(MinAfastamentoATR, 2.0);
   gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.8);
   gBreakEvenATR      = MathMax(BreakEvenATR,       1.5);

   if(gMinAfastamentoATR != MinAfastamentoATR)
      Print("AVISO v22: MinAfastamentoATR ", MinAfastamentoATR,
            " elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v22: SL_Folga_ATR ", SL_Folga_ATR,
            " elevado ao floor de ", gSL_Folga_ATR);
   if(gBreakEvenATR != BreakEvenATR)
      Print("AVISO v22: BreakEvenATR ", BreakEvenATR,
            " elevado ao floor de ", gBreakEvenATR);

   Print("v22 parametros efetivos | MinAfastATR:", gMinAfastamentoATR,
         " SL_Folga:", gSL_Folga_ATR, " BreakEven:", gBreakEvenATR,
         " SELL:", (PermitirVenda ? "ON" : "OFF"));

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

   if(UsarBreakEven && HasPosition())
      GerenciarBreakEven();

   if(barAtual != lastBar)
   {
      lastBar = barAtual;

      datetime hoje = (datetime)((long)TimeCurrent() / 86400 * 86400);
      if(hoje != diaAtual)
      {
         diaAtual         = hoje;
         tradesCompraHoje = 0;
         tradesVendaHoje  = 0;
      }

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
      if(ma20 <= 0 || ma200 <= 0 || atr <= 0) return;

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

         bool ok_MA200  = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_limite = (tradesVendaHoje  < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownVenda    == 0);
         bool ok_pavio  = (pavioSup         >= pavioMin);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao_venda)
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
                     " SL:", sl, " TP:", tp, " ATR:", atr);
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
         bool ok_limite = (tradesCompraHoje < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownCompra   == 0);
         bool ok_pavio  = (pavioInf         >= pavioMin);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao_compra)
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
                     " SL:", sl, " TP:", tp, " ATR:", atr);
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
         if(trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v22"))
            tradesCompraHoje++;
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
         if(trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v22"))
            tradesVendaHoje++;
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
void GerenciarBreakEven()
{
   double atr = GetBuffer(hATR, 1);
   if(atr <= 0) return;

   double alvo_be = atr * gBreakEvenATR;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      double abertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double slAtual  = PositionGetDouble(POSITION_SL);
      double tpAtual  = PositionGetDouble(POSITION_TP);
      double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(tipo == POSITION_TYPE_BUY)
      {
         if(slAtual >= abertura - _Point) continue;
         if((bid - abertura) >= alvo_be)
         {
            trade.PositionModify(ticket, NormalizeDouble(abertura, _Digits), tpAtual);
            Print("Break-even BUY | SL -> ", abertura);
         }
      }
      else if(tipo == POSITION_TYPE_SELL)
      {
         if(slAtual > 0 && slAtual <= abertura + _Point) continue;
         if((abertura - ask) >= alvo_be)
         {
            trade.PositionModify(ticket, NormalizeDouble(abertura, _Digits), tpAtual);
            Print("Break-even SELL | SL -> ", abertura);
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
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
      Print("SL em VENDA -> cooldown ", CooldownBarrasSL, " barras");
   }
   else if(tipo == DEAL_TYPE_SELL)
   {
      cooldownCompra = CooldownBarrasSL;
      Print("SL em COMPRA -> cooldown ", CooldownBarrasSL, " barras");
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
