//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v16.0                      |
//|   Saida Dinamica com guarda de barras | Base v14 + correcoes     |
//|  Diagnostico baseado no backteste v15 (USDJPY M5, Jan-Jun 2026) |
//+------------------------------------------------------------------+
//
//  COMPARATIVO DE VERSOES:
//  v13: +91.58 USD | 28 trades | BUY 54% acerto | SEM filtros RSI/ratio
//  v14: +17.43 EUR | 83 trades | 36% acerto     | RSI+ratio ON bloquearam
//  v15: -120.43EUR | 98 trades | 29% acerto     | saida dinamica precoce
//
//  DIAGNOSTICO v15:
//  [A] Saida dinamica C1>H2 disparava em 1-3 barras apos entrada ->
//      media winner 2.95 EUR (abaixo do SL medio de 3 EUR = R:R < 1)
//  [B] Falha Dupla com LookbackDupla=40 era sempre verdadeiro no M5 ->
//      nenhuma filtragem real, RSI relaxado automaticamente para 62/38
//  [C] RSI 65/35 + relaxamento automatico = threshold efetivo pior que v14
//
//  CORRECOES v16:
//  [1] Saida dinamica com MinBarrasHold:
//      SELL fecha quando C[1] > H[2] MAS apenas apos MinBarrasHold barras
//      BUY  fecha quando C[1] < L[2] MAS apenas apos MinBarrasHold barras
//      Isso da tempo ao trade se desenvolver antes de checar estrutura
//  [2] Remove Falha Dupla (nao funcionava em M5 com lookback 40 barras)
//  [3] RSI e ratio pavio/corpo desligados por padrao (como v13)
//      -> Recupera o volume e qualidade de sinais do v13 (54% BUY)
//  [4] Mantem toda a infraestrutura do v14 (ATR, break-even, stops)
//
//  SAIDA DINAMICA (especificacao):
//  SELL: fecha na abertura do candle apos aquele que fechou acima de H[2]
//  BUY:  fecha na abertura do candle apos aquele que fechou abaixo de L[2]
//  Somente verificado apos MinBarrasHold barras completas desde a entrada
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "16.00"
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

input group "=== THRESHOLDS EM ATR (multi-ativo / multi-TF) ==="
input double MinAfastamentoATR       = 0.8;   // Distancia minima da MA20 em multiplos de ATR
input double PavioMinimoATR          = 0.25;  // Pavio minimo para aceitar o setup
input double SL_Folga_ATR            = 0.5;   // Buffer para o SL alem do pavio

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 5;     // Barras minimas antes de checar saida (25 min no M5)
// SELL fecha se C[1] > H[2] apos MinBarrasHold barras
// BUY  fecha se C[1] < L[2] apos MinBarrasHold barras

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;

input group "=== FILTRO RSI (desligado por padrao - nao prejudicou v13) ==="
input bool   UsarFiltroRSI           = false;
input int    RSI_Periodo             = 14;
input int    LimiteRSI_Venda         = 60;
input int    LimiteRSI_Compra        = 40;

input group "=== FILTRO PAVIO/CORPO (desligado por padrao) ==="
input bool   UsarFiltroPavioCorpo    = false;
input double RatioPavioCorpo         = 1.5;

input group "=== GESTAO DE POSICAO ==="
input bool   UsarBreakEven           = true;
input double BreakEvenATR            = 1.0;   // Move SL para entrada quando lucro >= BreakEvenATR x ATR

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== GESTAO DE RISCO DIARIA ==="
input int    MaxTradesPorDirecao     = 2;
input int    CooldownBarrasSL        = 12;    // Barras bloqueadas apos SL (12=1h no M5)

input group "=== FILTRO DE HORARIO ==="
input bool   UsarFiltroHorario       = true;
input int    HoraInicio              = 7;
input int    HoraFim                 = 21;

input group "=== GERAL ==="
input ulong  MagicNumber             = 202409;

//==================================================================
//  HANDLES DE INDICADORES
//==================================================================
int hMA200, hMA20, hATR, hRSI;

//==================================================================
//  ESTADO PERSISTENTE ENTRE TICKS
//==================================================================
datetime lastBar        = 0;
datetime diaAtual       = 0;

bool   setupCompraAtivo = false;
bool   setupVendaAtivo  = false;
double precoGatilho     = 0.0;
double precoStopLoss    = 0.0;

int    tradesCompraHoje = 0;
int    tradesVendaHoje  = 0;
int    cooldownCompra   = 0;
int    cooldownVenda    = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   hMA200 = iMA (_Symbol, _Period, MA200_Period, 0, MODE_SMA, PRICE_CLOSE);
   hMA20  = iMA (_Symbol, _Period, MA20_Period,  0, MODE_SMA, PRICE_CLOSE);
   hATR   = iATR(_Symbol, _Period, ATR_Periodo);
   hRSI   = iRSI(_Symbol, _Period, RSI_Periodo, PRICE_CLOSE);

   if(hMA200 == INVALID_HANDLE || hMA20 == INVALID_HANDLE ||
      hATR   == INVALID_HANDLE || hRSI  == INVALID_HANDLE)
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
   IndicatorRelease(hRSI);
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
   // BLOCO 1 - Novo candle: gerencia saida ativa ou busca setup
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

      // Com posicao aberta: verifica saida dinamica e encerra analise
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
      double rsi   = GetBuffer(hRSI,   1);
      if(ma20 <= 0 || ma200 <= 0 || atr <= 0) return;
      if(UsarFiltroRSI && rsi <= 0) return;

      double C1 = iClose(_Symbol, _Period, 1);
      double H1 = iHigh (_Symbol, _Period, 1);
      double L1 = iLow  (_Symbol, _Period, 1);
      double O1 = iOpen (_Symbol, _Period, 1);
      double H2 = iHigh (_Symbol, _Period, 2);
      double L2 = iLow  (_Symbol, _Period, 2);

      double distMA20 = MathAbs(C1 - ma20);
      double distMin  = atr * MinAfastamentoATR;
      double pavioMin = atr * PavioMinimoATR;
      double slBuffer = atr * SL_Folga_ATR;
      double gatOff   = atr * 0.08;

      //------------------------------------------------------------
      // SETUP DE VENDA - Falha de Topo
      // Preco acima da MA20, candle rompeu maxima anterior e fechou
      // abaixo dela -> pavio superior = sinal de rejeicao (venda)
      //------------------------------------------------------------
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double corpo    = MathAbs(O1 - C1);
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200  = !UsarFiltroMA200    || (ma20 < ma200);
         bool ok_limite = (tradesVendaHoje     < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownVenda       == 0);
         bool ok_pavio  = (pavioSup            >= pavioMin);
         // Padrao: rompeu maxima anterior mas fechou de volta abaixo
         bool ok_padrao = (H1 > H2 && C1       <= H2);
         bool ok_rsi    = !UsarFiltroRSI       || (rsi > LimiteRSI_Venda);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo            < atr * 0.05)
                          || (pavioSup         >= RatioPavioCorpo * corpo);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao && ok_rsi && ok_ratio)
         {
            double gatilho = L1 - gatOff;    // Entra na perda da minima do candle de reversao
            double sl      = H1 + slBuffer;  // Stop acima do pavio da falha

            if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               setupVendaAtivo = true;
               Print("SETUP VENDA | L1:", L1, " SL:", sl, " ATR:", atr);
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      // Preco abaixo da MA20, candle perdeu minima anterior mas fechou
      // acima dela -> pavio inferior = sinal de rejeicao (compra)
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double corpo    = MathAbs(O1 - C1);
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200  = !UsarFiltroMA200    || (ma20 > ma200);
         bool ok_limite = (tradesCompraHoje    < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownCompra      == 0);
         bool ok_pavio  = (pavioInf            >= pavioMin);
         // Padrao: perdeu minima anterior mas fechou de volta acima
         bool ok_padrao = (L1 < L2 && C1       >= L2);
         bool ok_rsi    = !UsarFiltroRSI       || (rsi < LimiteRSI_Compra);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo            < atr * 0.05)
                          || (pavioInf         >= RatioPavioCorpo * corpo);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao && ok_rsi && ok_ratio)
         {
            double gatilho = H1 + gatOff;    // Entra na superacao da maxima do candle de reversao
            double sl      = L1 - slBuffer;  // Stop abaixo do pavio da falha

            if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               setupCompraAtivo = true;
               Print("SETUP COMPRA | H1:", H1, " SL:", sl, " ATR:", atr);
            }
         }
      }
   }

   //================================================================
   // BLOCO 2 - Intra-barra: aciona gatilho se preco cruzou o nivel
   //================================================================
   if(HasPosition()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(setupCompraAtivo && bid >= precoGatilho)
   {
      // TP = 0 (sem take-profit fixo; saida gerenciada dinamicamente)
      if(trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, 0, "Falha de Fundo v16"))
         tradesCompraHoje++;
      setupCompraAtivo = false;
      Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss);
   }

   if(setupVendaAtivo && ask <= precoGatilho)
   {
      if(trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, 0, "Falha de Topo v16"))
         tradesVendaHoje++;
      setupVendaAtivo = false;
      Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss);
   }
}

//+------------------------------------------------------------------+
//  VerificarSaidaDinamica
//  Chamado no inicio de cada nova barra quando ha posicao aberta.
//
//  Regra de saida:
//    SELL: fecha se C[1] (ultimo candle fechado) fechou ACIMA de H[2]
//          (maxima do candle anterior ao ultimo)
//    BUY:  fecha se C[1] fechou ABAIXO de L[2]
//          (minima do candle anterior ao ultimo)
//
//  Guarda MinBarrasHold: a verificacao SO ocorre apos MinBarrasHold
//  barras completas desde a abertura da posicao, evitando saidas
//  prematuras que eliminavam o potencial de lucro (bug do v15).
//+------------------------------------------------------------------+
void VerificarSaidaDinamica()
{
   double C1     = iClose(_Symbol, _Period, 1);
   double H2     = iHigh (_Symbol, _Period, 2);
   double L2     = iLow  (_Symbol, _Period, 2);
   long   segBar = (long)PeriodSeconds();
   if(segBar <= 0) segBar = 300; // fallback M5

   datetime barAbertura = iTime(_Symbol, _Period, 0);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      // Quantas barras completas se passaram desde a entrada?
      datetime openTime    = (datetime)PositionGetInteger(POSITION_TIME);
      long     barrasDecor = (long)(barAbertura - openTime) / segBar;
      if(barrasDecor < MinBarrasHold) continue; // ainda no periodo de guarda

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(tipo == POSITION_TYPE_SELL && C1 > H2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA VENDA (dinamica) C[1]:", C1, " > H[2]:", H2,
               " | barras:", barrasDecor);
      }
      else if(tipo == POSITION_TYPE_BUY && C1 < L2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA COMPRA (dinamica) C[1]:", C1, " < L[2]:", L2,
               " | barras:", barrasDecor);
      }
   }
}

//+------------------------------------------------------------------+
//  GerenciarBreakEven
//  Move SL para preco de abertura quando lucro >= BreakEvenATR x ATR.
//  Garante que a posicao nao resulta em perda apos atingir esse ganho.
//+------------------------------------------------------------------+
void GerenciarBreakEven()
{
   double atr = GetBuffer(hATR, 1);
   if(atr <= 0) return;

   double alvo_be = atr * BreakEvenATR;

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
         if(slAtual >= abertura - _Point) continue; // ja no break-even ou alem
         if((bid - abertura) >= alvo_be)
         {
            double novoSL = NormalizeDouble(abertura, _Digits);
            trade.PositionModify(ticket, novoSL, tpAtual);
            Print("Break-even BUY | SL -> ", novoSL);
         }
      }
      else if(tipo == POSITION_TYPE_SELL)
      {
         if(slAtual > 0 && slAtual <= abertura + _Point) continue;
         if((abertura - ask) >= alvo_be)
         {
            double novoSL = NormalizeDouble(abertura, _Digits);
            trade.PositionModify(ticket, novoSL, tpAtual);
            Print("Break-even SELL | SL -> ", novoSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//  OnTradeTransaction - detecta SL e ativa cooldown direcional
//  DEAL_TYPE_BUY  (saida) = fechou posicao VENDIDA  -> cooldownVenda
//  DEAL_TYPE_SELL (saida) = fechou posicao COMPRADA -> cooldownCompra
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
   if(profit >= 0.0) return; // cooldown apenas em SL, nao em saida dinamica/BE

   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(tipo == DEAL_TYPE_BUY) // fechou SELL com prejuizo = SL em venda
   {
      cooldownVenda = CooldownBarrasSL;
      Print("SL em VENDA -> cooldown ", CooldownBarrasSL, " barras");
   }
   else if(tipo == DEAL_TYPE_SELL) // fechou BUY com prejuizo = SL em compra
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
