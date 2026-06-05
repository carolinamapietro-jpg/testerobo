//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v18.0                      |
//|  SaidaDinamicaMinRR: guard de preco no lucro | parametros M2/M5  |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v17 (USDJPY M2, Jan-Jun 2026, 5 meses):
//  - Resultado: -89.28 EUR | 146 trades | 42.47% acerto
//  - Avg win: 2.10 EUR | Avg loss: -2.62 EUR | R:R REAL: 0.80 !!
//  - Duracao media: 12 min = 6 barras no M2
//  - Maior loss consecutivo: 11 trades
//  - Parametros usados: MinAfastamentoATR=0.8, SL_Folga_ATR=0.5 (antigos v16)
//                        RSI e PavioCorpo habilitados pelo usuario
//
//  ROOT CAUSE CENTRAL:
//  Guard "profit > 0" na saida dinamica permite fechar com lucro de
//  0.01 pip. No M2, apos 10 barras, C[1]>H[2] dispara frequentemente
//  com a posicao em lucro MINIMO -> winners cortados em 2.10 EUR
//  em vez de atingir o TP de 5.24 EUR (2:1 esperado). R:R real = 0.80.
//
//  CORRECAO PRINCIPAL - SaidaDinamicaMinRR:
//  Saida dinamica so dispara se lucro em PRECO >= risco_preco x MinRR
//  onde risco_preco = distancia SL-entrada em pontos de preco.
//  Com MinRR=1.0: posicao precisa atingir 1:1 R:R antes de sair
//  dinamicamente -> media de winners sobe de 2.10 para ~4-5 EUR.
//
//  CORRECOES v18:
//  [1] SaidaDinamicaMinRR=1.0: guard preco na saida dinamica
//      Substitui "profit>0" por lucroPreco >= riscoPreco * MinRR
//      Apos break-even (risco=0), qualquer lucro permite saida (correto)
//  [2] BreakEvenATR: 1.0 -> 1.5 (mais espaco antes de mover SL)
//  [3] MinAfastamentoATR: 1.2 -> 1.5 (mais seletivo, menos ruido)
//  [4] SL_Folga_ATR: 0.8 -> 1.0 (SL mais largo, menos stops no ruido)
//  [5] MinBarrasHold: 10 -> 15 barras
//  [6] RSI default: LimiteRSI_Venda 60->65, LimiteRSI_Compra 40->35
//      Quando habilitado, filtra apenas extremos reais
//
//  LOGICA DE SAIDA (ordem de prioridade):
//  1. SL fixo: se preco vai contra -> SL executa
//  2. TP fixo (2xSL): se preco atinge alvo -> TP executa
//  3. Saida dinamica (em lucro >= 1:1 R:R): se padrao reverte
//     apos posicao ja estar 1xSL em lucro -> fecha antecipado
//  4. Break-even: move SL para entrada apos 1.5xATR de lucro
//
//  COMPARATIVO:
//  v13: +91.58 EUR | 1 ano M5  | sem saida dinamica
//  v16: -11.77 EUR | 5 meses M5 | saida din. s/ guard adequado
//  v17: -89.28 EUR | 5 meses M2 | saida din. com profit>0 (cortou winners)
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "18.00"
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
input double RiscoRetorno            = 2.0;    // Multiplicador TP/SL (0 = sem TP fixo)

input group "=== THRESHOLDS EM ATR (multi-ativo / multi-TF) ==="
input double MinAfastamentoATR       = 1.5;    // Distancia minima da MA20 (era 0.8; v13 ~1.5)
input double PavioMinimoATR          = 0.25;   // Pavio minimo do candle de sinal
input double SL_Folga_ATR            = 1.0;    // Buffer SL alem do pavio (era 0.5 no v17 usado)

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;     // Barras minimas antes de checar saida (era 10)
input double SaidaDinamicaMinRR      = 1.0;    // Lucro minimo em R:R antes de fechar dinamicamente
// Saida dinamica SO dispara se lucroPreco >= riscoPreco x SaidaDinamicaMinRR
// Evita cortar winners com lucro minimo (bug principal do v17)
// Apos break-even (SL = entrada, risco=0), qualquer lucro permite saida

input group "=== FILTRO DE MEDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;

input group "=== FILTRO RSI (desligado por padrao - use apenas em extremos) ==="
input bool   UsarFiltroRSI           = false;
input int    RSI_Periodo             = 14;
input int    LimiteRSI_Venda         = 65;    // Era 60; 65+ e mais confiavel como extremo
input int    LimiteRSI_Compra        = 35;    // Era 40; 35- e mais confiavel como extremo

input group "=== FILTRO PAVIO/CORPO (desligado por padrao) ==="
input bool   UsarFiltroPavioCorpo    = false;
input double RatioPavioCorpo         = 1.5;

input group "=== GESTAO DE POSICAO ==="
input bool   UsarBreakEven           = true;
input double BreakEvenATR            = 1.5;   // Era 1.0; mais espaco antes de mover SL

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
   // BLOCO 1 - Novo candle: verifica saida ativa ou busca setup
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
      // Candle rompeu maxima anterior mas fechou abaixo dela.
      // ok_corpo exige close < open: confirma rejeicao bearish real.
      //------------------------------------------------------------
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double pavioSup = H1 - MathMax(O1, C1);
         double corpo    = MathAbs(O1 - C1);

         bool ok_MA200  = !UsarFiltroMA200     || (ma20 < ma200);
         bool ok_limite = (tradesVendaHoje      < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownVenda        == 0);
         bool ok_pavio  = (pavioSup             >= pavioMin);
         bool ok_padrao = (H1 > H2 && C1        <= H2);
         bool ok_corpo  = (C1                   <  O1);  // corpo bearish obrigatorio
         bool ok_rsi    = !UsarFiltroRSI        || (rsi > LimiteRSI_Venda);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo             < atr * 0.05)
                          || (pavioSup          >= RatioPavioCorpo * corpo);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao &&
            ok_corpo && ok_rsi && ok_ratio)
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
               Print("SETUP VENDA | L1:", L1, " SL:", sl, " TP:", tp, " ATR:", atr);
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      // Candle perdeu minima anterior mas fechou acima dela.
      // ok_corpo exige close > open: confirma rejeicao bullish real.
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double pavioInf = MathMin(O1, C1) - L1;
         double corpo    = MathAbs(O1 - C1);

         bool ok_MA200  = !UsarFiltroMA200     || (ma20 > ma200);
         bool ok_limite = (tradesCompraHoje     < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownCompra       == 0);
         bool ok_pavio  = (pavioInf             >= pavioMin);
         bool ok_padrao = (L1 < L2 && C1        >= L2);
         bool ok_corpo  = (C1                   >  O1);  // corpo bullish obrigatorio
         bool ok_rsi    = !UsarFiltroRSI        || (rsi < LimiteRSI_Compra);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo             < atr * 0.05)
                          || (pavioInf          >= RatioPavioCorpo * corpo);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao &&
            ok_corpo && ok_rsi && ok_ratio)
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
               Print("SETUP COMPRA | H1:", H1, " SL:", sl, " TP:", tp, " ATR:", atr);
            }
         }
      }
   }

   //================================================================
   // BLOCO 2 - Intra-barra: dispara entrada se preco cruzou gatilho
   //================================================================
   if(HasPosition()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(setupCompraAtivo && bid >= precoGatilho)
   {
      if(trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v18"))
         tradesCompraHoje++;
      setupCompraAtivo = false;
      Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss, " TP:", precoTakeProfit);
   }

   if(setupVendaAtivo && ask <= precoGatilho)
   {
      if(trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v18"))
         tradesVendaHoje++;
      setupVendaAtivo = false;
      Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss, " TP:", precoTakeProfit);
   }
}

//+------------------------------------------------------------------+
//  VerificarSaidaDinamica
//  Fecha posicao quando estrutura de mercado reverte, COM GUARD DE PRECO.
//
//  GUARD SaidaDinamicaMinRR:
//    Calcula risco em preco: |SL - entrada|
//    Calcula lucro em preco: |preco_atual - entrada| (na direcao correta)
//    So fecha se lucroPreco >= riscoPreco * SaidaDinamicaMinRR
//
//    Isso garante que a saida dinamica so ocorre quando a posicao
//    ja atingiu SaidaDinamicaMinRR:1 de R:R, evitando cortar winners
//    com lucro minimo (era o bug central do v17 no M2).
//
//    Caso especial - break-even ativo (SL = entrada):
//    riscoPreco = 0 -> guard sempre passa -> qualquer lucro permite saida
//    Comportamento correto: apos break-even, protege qualquer ganho.
//
//  GUARD MinBarrasHold:
//    Alem do MinRR, espera MinBarrasHold barras completas desde entrada.
//+------------------------------------------------------------------+
void VerificarSaidaDinamica()
{
   double C1     = iClose(_Symbol, _Period, 1);
   double H2     = iHigh (_Symbol, _Period, 2);
   double L2     = iLow  (_Symbol, _Period, 2);
   long   segBar = (long)PeriodSeconds();
   if(segBar <= 0) segBar = 120; // fallback M2

   datetime barAbertura = iTime(_Symbol, _Period, 0);
   double   bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double   ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      // Guard 1: espera barras minimas
      datetime openTime    = (datetime)PositionGetInteger(POSITION_TIME);
      long     barrasDecor = (long)(barAbertura - openTime) / segBar;
      if(barrasDecor < MinBarrasHold) continue;

      ENUM_POSITION_TYPE tipo    = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double             abertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double             slPos    = PositionGetDouble(POSITION_SL);

      // Risco original em pontos de preco (distancia SL-entrada)
      // Quando SL=entrada (break-even), riscoPreco=0 e guard sempre passa
      double riscoPreco = MathAbs(slPos - abertura);

      // Lucro atual em pontos de preco (movimento favoravel desde entrada)
      double lucroPreco = 0;
      if(tipo == POSITION_TYPE_SELL)
         lucroPreco = abertura - ask; // positivo quando preco caiu (SELL em lucro)
      else
         lucroPreco = bid - abertura; // positivo quando preco subiu (BUY em lucro)

      // Guard 2: lucro em preco deve ser >= riscoPreco * SaidaDinamicaMinRR
      // Garante que winners so sao fechados apos atingir R:R minimo
      if(lucroPreco < riscoPreco * SaidaDinamicaMinRR) continue;

      // Condicao de reversao de estrutura
      if(tipo == POSITION_TYPE_SELL && C1 > H2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA VENDA (din) C[1]:", C1, " > H[2]:", H2,
               " lucroPreco:", lucroPreco, " riscoPreco:", riscoPreco,
               " barras:", barrasDecor);
      }
      else if(tipo == POSITION_TYPE_BUY && C1 < L2)
      {
         trade.PositionClose(ticket);
         Print("SAIDA COMPRA (din) C[1]:", C1, " < L[2]:", L2,
               " lucroPreco:", lucroPreco, " riscoPreco:", riscoPreco,
               " barras:", barrasDecor);
      }
   }
}

//+------------------------------------------------------------------+
//  GerenciarBreakEven
//  Move SL para preco de abertura quando lucro >= BreakEvenATR x ATR.
//  BreakEvenATR=1.5 da mais espaco que o v17 (era 1.0).
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
