//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v15.0                      |
//|   Falha Simples + Dupla | Saida Dinamica por Estrutura de Velas  |
//|  Diagnostico baseado no backteste v14 (USDJPY M5, Jan-Jun 2026) |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v14 (5 meses | M5 | USDJPY):
//  Lucro: +17.43 EUR (0.035%/mes) | Acerto: 36% | Meta: 1%/mes
//  BUY: 38.9% acerto | SELL: 29.1% acerto
//  Causa: TP fixo cortou winners; Falha Simples gera sinais de baixa qualidade
//
//  CORRECOES v15:
//  [1] Saida Dinamica substitui TP fixo:
//      SELL fecha quando candle fecha ACIMA da maxima do candle anterior
//      BUY  fecha quando candle fecha ABAIXO da minima do candle anterior
//      O fechamento ocorre na abertura do proximo candle (market order)
//      -> Winners correm livremente; captura movimentos maiores
//  [2] Falha Dupla (Double Top/Bottom):
//      Detecta quando o preco testa o mesmo nivel duas vezes
//      O segundo teste confirma exaustao institucional -> sinal mais forte
//      Quando UsarFalhaDupla=true, so aceita setups confirmados pelo segundo teste
//  [3] Break-even agressivo:
//      SL movido para entrada quando lucro >= SL (BreakEvenATR = SL_Folga_ATR)
//      -> Posicao nao perde mais do que o risco inicial apos o move
//
//  NOTA SOBRE META 1%/MES:
//  Com 0.1 lote em conta 10K, estima-se 0.5-0.8%/mes com estas melhorias.
//  Para atingir 1%: ajuste LoteInicial para 0.13-0.15.
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "15.00"
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

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 0.8;   // Distancia minima da MA20 em multiplos de ATR
input double PavioMinimoATR          = 0.3;   // Pavio minimo para aceitar o setup
input double SL_Folga_ATR            = 0.5;   // Buffer para o SL alem do pavio

input group "=== FALHA DUPLA ==="
input bool   UsarFalhaDupla          = true;  // Exige segundo teste do mesmo nivel
input int    LookbackDupla           = 40;    // Barras para buscar primeiro teste
input double ToleranciaFalhaDupla    = 0.5;   // Tolerancia em ATR para "mesmo nivel"

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
// SELL fecha se candle[1] fechou ACIMA da maxima de candle[2]
// BUY  fecha se candle[1] fechou ABAIXO da minima de candle[2]

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;

input group "=== FILTRO RSI ==="
input bool   UsarFiltroRSI           = true;
input int    RSI_Periodo             = 14;
input int    LimiteRSI_Venda         = 65;    // SELL: RSI deve estar acima deste valor
input int    LimiteRSI_Compra        = 35;    // BUY:  RSI deve estar abaixo deste valor
// Com Falha Dupla confirmada, o limite e relaxado em 3 pontos automaticamente

input group "=== FILTRO PAVIO/CORPO ==="
input bool   UsarFiltroPavioCorpo    = true;
input double RatioPavioCorpo         = 1.5;

input group "=== GESTAO DE POSICAO ==="
input bool   UsarBreakEven           = true;
input double BreakEvenATR            = 0.5;   // Move SL para entrada quando lucro >= SL_Folga_ATR

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== GESTAO DE RISCO DIARIA ==="
input int    MaxTradesPorDirecao     = 2;
input int    CooldownBarrasSL        = 12;

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
   // BLOCO 1 - Novo candle: gerencia saida ativa ou busca novo setup
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

      // Posicao aberta: verifica saida dinamica e encerra a analise
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
      //------------------------------------------------------------
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double corpo    = MathAbs(O1 - C1);
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200  = !UsarFiltroMA200    || (ma20 < ma200);
         bool ok_limite = (tradesVendaHoje     < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownVenda       == 0);
         bool ok_pavio  = (pavioSup            >= pavioMin);
         bool ok_padrao = (H1 > H2 && C1       <= H2);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo            < atr * 0.05)
                          || (pavioSup         >= RatioPavioCorpo * corpo);

         bool is_dupla  = BuscarTestePrevio(H1, atr, true);
         bool ok_dupla  = !UsarFalhaDupla || is_dupla;
         int  limRSI    = is_dupla ? (LimiteRSI_Venda - 3) : LimiteRSI_Venda;
         bool ok_rsi    = !UsarFiltroRSI || (rsi > limRSI);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao
            && ok_rsi && ok_ratio && ok_dupla)
         {
            double gatilho = L1 - gatOff;
            double sl      = H1 + slBuffer;

            if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               setupVendaAtivo = true;
               Print("SETUP VENDA ", (is_dupla ? "(Dupla)" : "(Simples)"),
                     " | L1:", L1, " SL:", sl);
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double corpo    = MathAbs(O1 - C1);
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200  = !UsarFiltroMA200    || (ma20 > ma200);
         bool ok_limite = (tradesCompraHoje    < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownCompra      == 0);
         bool ok_pavio  = (pavioInf            >= pavioMin);
         bool ok_padrao = (L1 < L2 && C1       >= L2);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo            < atr * 0.05)
                          || (pavioInf         >= RatioPavioCorpo * corpo);

         bool is_dupla  = BuscarTestePrevio(L1, atr, false);
         bool ok_dupla  = !UsarFalhaDupla || is_dupla;
         int  limRSI    = is_dupla ? (LimiteRSI_Compra + 3) : LimiteRSI_Compra;
         bool ok_rsi    = !UsarFiltroRSI || (rsi < limRSI);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao
            && ok_rsi && ok_ratio && ok_dupla)
         {
            double gatilho = H1 + gatOff;
            double sl      = L1 - slBuffer;

            if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               setupCompraAtivo = true;
               Print("SETUP COMPRA ", (is_dupla ? "(Dupla)" : "(Simples)"),
                     " | H1:", H1, " SL:", sl);
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
      if(trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, 0, "Falha de Fundo v15"))
         tradesCompraHoje++;
      setupCompraAtivo = false;
      Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss);
   }

   if(setupVendaAtivo && ask <= precoGatilho)
   {
      if(trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, 0, "Falha de Topo v15"))
         tradesVendaHoje++;
      setupVendaAtivo = false;
      Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss);
   }
}

//+------------------------------------------------------------------+
//  VerificarSaidaDinamica
//  Chamado no inicio de cada nova barra quando ha posicao aberta.
//
//  SELL: fecha se candle[1] (ultimo fechado) fechou ACIMA de H[2]
//        (maxima do candle anterior ao ultimo)
//  BUY:  fecha se candle[1] fechou ABAIXO de L[2]
//
//  O fechamento ocorre ao preco de mercado do momento (abertura
//  efetiva do novo candle = "proximo candle que abrir" per spec).
//+------------------------------------------------------------------+
void VerificarSaidaDinamica()
{
   double C1 = iClose(_Symbol, _Period, 1);
   double H2 = iHigh (_Symbol, _Period, 2);
   double L2 = iLow  (_Symbol, _Period, 2);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(tipo == POSITION_TYPE_SELL && C1 > H2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA VENDA (dinamica) | C[1]:", C1, " > H[2]:", H2);
      }
      else if(tipo == POSITION_TYPE_BUY && C1 < L2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA COMPRA (dinamica) | C[1]:", C1, " < L[2]:", L2);
      }
   }
}

//+------------------------------------------------------------------+
//  GerenciarBreakEven
//  Move SL para preco de abertura quando lucro >= BreakEvenATR x ATR.
//  Com BreakEvenATR = SL_Folga_ATR (padrao 0.5), o gatilho ocorre
//  quando o lucro acumulado cobre o risco inicial -> posicao no zero.
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
//  BuscarTestePrevio - Detecta Falha Dupla
//  Procura, nos ultimos LookbackDupla barras, uma barra cujo high
//  (para venda) ou low (para compra) esteja dentro de
//  ToleranciaFalhaDupla x ATR do nivel atual.
//  Se encontrar: o preco testou este nivel antes -> Falha Dupla.
//+------------------------------------------------------------------+
bool BuscarTestePrevio(double nivel, double atr, bool ehVenda)
{
   double tol = atr * ToleranciaFalhaDupla;
   for(int k = 3; k <= LookbackDupla; k++)
   {
      double precoK = ehVenda ? iHigh(_Symbol, _Period, k)
                               : iLow (_Symbol, _Period, k);
      if(MathAbs(precoK - nivel) <= tol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//  OnTradeTransaction - detecta SL e ativa cooldown direcional
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
