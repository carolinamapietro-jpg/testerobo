//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v20.0                      |
//|  Floors de parametros + correcao dos gatilhos de entrada          |
//+------------------------------------------------------------------+
//
//  CAUSA RAIZ DO PREJUIZO NO v19 (analise quantitativa):
//
//  O usuario carrega parametros antigos em cache do MetaTester:
//    MinAfastamentoATR = 0.8  (default v19 = 1.5)
//    SL_Folga_ATR      = 0.5  (default v19 = 1.0)
//    BreakEvenATR      = 1.0  (default v19 = 1.5)
//
//  Efeito mensuravel no backteste:
//    v19 com 0.8 => 512 trades/ano, win rate 38.28% => -99.81 EUR
//    v13 com 1.5 => ~28 trades/ano, win rate 54% => +91.58 EUR
//
//  Com MinAfastamentoATR=0.8 o EA aceita sinais fracos onde o preco
//  esta muito proximo da MA20. Esses setups tem probabilidade de
//  reversao muito menor que setups com afastamento >= 1.5 x ATR.
//  Resultado: 512 trades vs ~145 esperados com o threshold correto,
//  e win rate 38.28% vs break-even necessario de 40.4%.
//
//  CORRECOES v20:
//  [1] Floors obrigatorios implementados em variaveis globais:
//      gMinAfastamentoATR = MathMax(MinAfastamentoATR, 1.5)
//      gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.8)
//      gBreakEvenATR      = MathMax(BreakEvenATR,       1.5)
//      Qualquer valor de parametro abaixo do floor e silenciosamente
//      elevado. Log de aviso e emitido no OnInit.
//  [2] Correcao dos gatilhos de entrada:
//      COMPRA: era (bid >= gatilho), corrigido para (ask >= gatilho)
//        - compra executa em ask; checar ask garante entrada no nivel
//      VENDA:  era (ask <= gatilho), corrigido para (bid <= gatilho)
//        - venda executa em bid; checar bid garante entrada no nivel
//  [3] Mantido tudo do v19: disambiguacao de outside bars, remocao
//      de ok_corpo geral, sem RSI, sem PavioCorpo, SaidaDinamicaMinRR.
//
//  LOGICA DE PADRAO (identica ao v13/v19):
//  SELL: H1>H2 && C1<=H2 (falha acima da maxima anterior)
//  BUY:  L1<L2 && C1>=L2 (falha abaixo da minima anterior)
//  Corpo so e usado quando ambos os padroes ocorrem no mesmo candle.
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "20.00"
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
input bool   PermitirVenda           = true;

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 0.1;
input double RiscoRetorno            = 2.0;   // Multiplo TP/SL (0 = sem TP fixo)

input group "=== THRESHOLDS EM ATR (multi-ativo / multi-TF) ==="
input double MinAfastamentoATR       = 1.5;   // Distancia minima da MA20 em ATR (floor: 1.5)
input double PavioMinimoATR          = 0.25;  // Pavio minimo do candle de sinal
input double SL_Folga_ATR            = 1.0;   // Buffer SL alem do extremo do pavio (floor: 0.8)

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;    // Barras minimas antes de checar saida
input double SaidaDinamicaMinRR      = 1.0;   // Lucro minimo (x risco) antes de fechar
// Saida dinamica: SELL fecha se C[1]>H[2] | BUY fecha se C[1]<L[2]
// Condicao adicional: lucroPreco >= riscoPreco * SaidaDinamicaMinRR
// Apos break-even (SL=entrada, risco=0): qualquer lucro permite saida

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
//  Impede que parametros em cache do usuario reduzam a qualidade
//  dos sinais abaixo do nivel minimo necessario para lucratividade.
//==================================================================
double gMinAfastamentoATR;  // floor: 1.5
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

int    tradesCompraHoje  = 0;
int    tradesVendaHoje   = 0;
int    cooldownCompra    = 0;
int    cooldownVenda     = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   // Aplicar floors — protege contra parametros antigos em cache
   gMinAfastamentoATR = MathMax(MinAfastamentoATR, 1.5);
   gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.8);
   gBreakEvenATR      = MathMax(BreakEvenATR,       1.5);

   if(gMinAfastamentoATR != MinAfastamentoATR)
      Print("AVISO v20: MinAfastamentoATR ", MinAfastamentoATR,
            " elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v20: SL_Folga_ATR ", SL_Folga_ATR,
            " elevado ao floor de ", gSL_Folga_ATR);
   if(gBreakEvenATR != BreakEvenATR)
      Print("AVISO v20: BreakEvenATR ", BreakEvenATR,
            " elevado ao floor de ", gBreakEvenATR);

   Print("v20 parametros efetivos | MinAfastATR:", gMinAfastamentoATR,
         " SL_Folga:", gSL_Folga_ATR, " BreakEven:", gBreakEvenATR);

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

   //================================================================
   // BLOCO 0 - Break-even (a cada tick enquanto ha posicao aberta)
   //================================================================
   if(UsarBreakEven && HasPosition())
      GerenciarBreakEven();

   //================================================================
   // BLOCO 1 - Novo candle
   //================================================================
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
      double distMin  = atr * gMinAfastamentoATR;  // usa floor
      double pavioMin = atr * PavioMinimoATR;
      double slBuffer = atr * gSL_Folga_ATR;        // usa floor
      double gatOff   = atr * 0.08;

      // Padroes primarios (identicos ao v13/v19)
      bool sell_cond = (H1 > H2 && C1 <= H2); // Falha de Topo: rompeu max e fechou abaixo
      bool buy_cond  = (L1 < L2 && C1 >= L2); // Falha de Fundo: perdeu min e fechou acima

      // Desambiguacao: quando AMBOS os padroes ocorrem no mesmo candle
      // (outside bar), usa o corpo para decidir direcao.
      // Quando apenas UM padrao ocorre, corpo NAO e exigido.
      bool ok_padrao_venda  = sell_cond && (!buy_cond  || C1 < O1);
      bool ok_padrao_compra = buy_cond  && (!sell_cond || C1 > O1);

      //------------------------------------------------------------
      // SETUP DE VENDA - Falha de Topo
      //------------------------------------------------------------
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200  = !UsarFiltroMA200  || (ma20 < ma200);
         bool ok_limite = (tradesVendaHoje   < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownVenda     == 0);
         bool ok_pavio  = (pavioSup          >= pavioMin);

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
                     " SL:", sl, " TP:", tp, " ATR:", atr,
                     " distMA:", DoubleToString(distMA20/atr, 2), "xATR");
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200  = !UsarFiltroMA200  || (ma20 > ma200);
         bool ok_limite = (tradesCompraHoje  < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownCompra    == 0);
         bool ok_pavio  = (pavioInf          >= pavioMin);

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
                     " SL:", sl, " TP:", tp, " ATR:", atr,
                     " distMA:", DoubleToString(distMA20/atr, 2), "xATR");
            }
         }
      }
   }

   //================================================================
   // BLOCO 2 - Intra-barra: dispara entrada se preco cruzou gatilho
   //
   // CORRECAO v20: BUY verifica ask (preco de compra) >= gatilho;
   //               SELL verifica bid (preco de venda) <= gatilho.
   // Anteriormente BUY usava bid e SELL usava ask, causando entradas
   // sistematicamente deslocadas por um spread do nivel de gatilho.
   //================================================================
   if(HasPosition()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(setupCompraAtivo && ask >= precoGatilho)
   {
      if(trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v20"))
         tradesCompraHoje++;
      setupCompraAtivo = false;
      Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss, " TP:", precoTakeProfit);
   }

   if(setupVendaAtivo && bid <= precoGatilho)
   {
      if(trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v20"))
         tradesVendaHoje++;
      setupVendaAtivo = false;
      Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss, " TP:", precoTakeProfit);
   }
}

//+------------------------------------------------------------------+
//  VerificarSaidaDinamica
//  SELL: fecha se C[1] > H[2]  (fechamento acima da max do candle anterior)
//  BUY:  fecha se C[1] < L[2]  (fechamento abaixo da min do candle anterior)
//
//  Guards obrigatorios:
//  1. MinBarrasHold: so verifica apos N barras completas desde entrada
//  2. SaidaDinamicaMinRR: lucroPreco >= riscoPreco * MinRR
//     Quando SL=entrada (break-even, risco=0): guard passa sempre
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
               " RR:", (riscoPreco > 0 ? lucroPreco/riscoPreco : 0),
               " barras:", barrasDecor);
      }
      else if(tipo == POSITION_TYPE_BUY && C1 < L2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA COMPRA (din) C[1]:", C1, " < L[2]:", L2,
               " RR:", (riscoPreco > 0 ? lucroPreco/riscoPreco : 0),
               " barras:", barrasDecor);
      }
   }
}

//+------------------------------------------------------------------+
void GerenciarBreakEven()
{
   double atr = GetBuffer(hATR, 1);
   if(atr <= 0) return;

   double alvo_be = atr * gBreakEvenATR;  // usa floor

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
