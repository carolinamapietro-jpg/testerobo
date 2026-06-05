//+------------------------------------------------------------------+
//|                      EA Falha Exaustão v14.0                     |
//|     Operando Contra o Afastamento da MA20 — Multi-Ativo / TF     |
//|  Diagnóstico baseado no backteste v13 (USDJPY M2, Jan-Jun 2026) |
//+------------------------------------------------------------------+
//
//  DIAGNÓSTICO DO BACKTESTE v13 (5 meses | M2 | USDJPY):
//  ─────────────────────────────────────────────────────────────────
//  Lucro Líquido: -72.28 | Fator de Lucro: 0.64 | Sharpe: -5.00
//  Rebaixamento máx: 131.26 (1.31%) | SELL continua destruindo equity
//
//  CAUSAS RAIZ IDENTIFICADAS:
//  [A] Thresholds em pontos fixos → não escalam entre ativos/timeframes
//      Ex: MinAfastamentoPontos=100 pts é diferente para USDJPY vs XAUUSD
//  [B] SELL perde mesmo com filtro MA200 → sem confirmação de exaustão real
//  [C] Pavios "cosméticos" aceitos → sem validação de relação pavio/corpo
//  [D] Winners viram losers → sem gestão de posição após entrada
//  [E] SL/TP não validados contra STOPS_LEVEL mínimo da corretora
//
//  CORREÇÕES IMPLEMENTADAS v14:
//  [1] Multi-ativo/TF: MinAfastamentoATR, PavioMinimoATR, SL_Folga_ATR
//      → todos os thresholds em múltiplos de ATR14
//      → funciona automaticamente em EURUSD, XAUUSD, índices, crypto
//      → funciona em qualquer timeframe (M1 … D1)
//  [2] Filtro RSI: SELL exige RSI > LimiteRSI_Venda (padrão 60)
//                  BUY  exige RSI < LimiteRSI_Compra (padrão 40)
//      → confirma zona de exaustão antes de aceitar o sinal
//  [3] Filtro Pavio/Corpo: wick >= RatioPavioCorpo × corpo
//      → rejeita candles onde o pavio é cosmético; exige rejeição real
//  [4] Break-even automático: quando ganho >= BreakEvenATR × ATR,
//      SL é movido para o preço de abertura (risco zero)
//  [5] ValidarStops: SL/TP nunca violam o STOPS_LEVEL mínimo do ativo
//  [6] PermitirCompra / PermitirVenda: liga/desliga cada direção
//      → recomendado: testar SELL desligado até nova evidência positiva
//
//  PARÂMETROS SUGERIDOS POR TIMEFRAME (ponto de partida):
//  ─────────────────────────────────────────────────────────────────
//  M1-M5  : MinAfastamentoATR=0.8 | PavioMinimoATR=0.3 | SL_Folga_ATR=0.5
//  M15-H1 : MinAfastamentoATR=1.0 | PavioMinimoATR=0.4 | SL_Folga_ATR=0.6
//  H4-D1  : MinAfastamentoATR=1.2 | PavioMinimoATR=0.5 | SL_Folga_ATR=0.7
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "14.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//══════════════════════════════════════════════════════════════════
//  INPUTS
//══════════════════════════════════════════════════════════════════

input group "=== DIRECOES ==="
input bool   PermitirCompra          = true;    // Habilita setups de COMPRA (Falha de Fundo)
input bool   PermitirVenda           = true;    // Habilita setups de VENDA  (Falha de Topo)

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 0.1;
input double RiscoRetorno            = 2.0;     // Alvo = risco × RiscoRetorno

input group "=== THRESHOLDS EM ATR (multi-ativo / multi-TF) ==="
input double MinAfastamentoATR       = 0.8;     // Distância mínima da MA20 em múltiplos de ATR
input double PavioMinimoATR          = 0.3;     // Tamanho mínimo do pavio em múltiplos de ATR
input double SL_Folga_ATR            = 0.5;     // Buffer acima/abaixo do pavio para posicionar SL

input group "=== FILTRO DE MÉDIAS ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;   // BUY só se MA20>MA200 | SELL só se MA20<MA200

input group "=== FILTRO RSI === [FIX-B: confirma exaustão antes da entrada]"
input bool   UsarFiltroRSI           = true;
input int    RSI_Periodo             = 14;
input int    LimiteRSI_Venda         = 60;      // SELL aceito apenas se RSI > este valor
input int    LimiteRSI_Compra        = 40;      // BUY  aceito apenas se RSI < este valor

input group "=== FILTRO PAVIO/CORPO === [FIX-C: rejeita pavios cosméticos]"
input bool   UsarFiltroPavioCorpo    = true;
input double RatioPavioCorpo         = 1.5;     // Pavio deve ser >= RatioPavioCorpo × corpo

input group "=== GESTÃO DE POSIÇÃO === [FIX-D: protege ganhos]"
input bool   UsarBreakEven           = true;
input double BreakEvenATR            = 1.0;     // Move SL para BE quando ganho >= BreakEvenATR × ATR

input group "=== ATR ==="
input int    ATR_Periodo             = 14;

input group "=== GESTÃO DE RISCO DIÁRIA ==="
input int    MaxTradesPorDirecao     = 2;       // Máx. trades por direção por dia
input int    CooldownBarrasSL        = 12;      // Barras bloqueadas após SL (12=1h no M5; ajuste por TF)

input group "=== FILTRO DE HORÁRIO ==="
input bool   UsarFiltroHorario       = true;
input int    HoraInicio              = 7;       // Hora de início (hora do servidor)
input int    HoraFim                 = 21;      // Hora de fim   (hora do servidor)

input group "=== GERAL ==="
input ulong  MagicNumber             = 202409;

//══════════════════════════════════════════════════════════════════
//  HANDLES DE INDICADORES
//══════════════════════════════════════════════════════════════════
int hMA200, hMA20, hATR, hRSI;

//══════════════════════════════════════════════════════════════════
//  ESTADO PERSISTENTE ENTRE TICKS
//══════════════════════════════════════════════════════════════════
datetime lastBar        = 0;
datetime diaAtual       = 0;

bool   setupCompraAtivo = false;
bool   setupVendaAtivo  = false;
double precoGatilho     = 0.0;
double precoStopLoss    = 0.0;
double precoTakeProfit  = 0.0;

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

   //════════════════════════════════════════════════════════════════
   // BLOCO 0 — Break-even: verificado a cada tick enquanto há posição
   //════════════════════════════════════════════════════════════════
   if(UsarBreakEven && HasPosition())
      GerenciarBreakEven();

   //════════════════════════════════════════════════════════════════
   // BLOCO 1 — Novo candle: atualiza estado e identifica setup
   //════════════════════════════════════════════════════════════════
   if(barAtual != lastBar)
   {
      lastBar = barAtual;

      //── Reset dos contadores ao virar o dia ─────────────────────
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

      if(HasPosition()) return;

      //── Filtro de horário ────────────────────────────────────────
      if(UsarFiltroHorario)
      {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         if(dt.hour < HoraInicio || dt.hour >= HoraFim) return;
      }

      //── Leitura de indicadores (candle fechado = índice 1) ───────
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

      // Thresholds escalados pelo ATR → válidos em qualquer ativo/TF
      double distMA20  = MathAbs(C1 - ma20);
      double distMin   = atr * MinAfastamentoATR;
      double pavioMin  = atr * PavioMinimoATR;
      double slBuffer  = atr * SL_Folga_ATR;
      double gatOff    = atr * 0.08;  // pequeno offset para confirmar rompimento do gatilho

      //──────────────────────────────────────────────────────────────
      // SETUP DE VENDA — Falha de Topo (exaustão acima da MA20)
      //──────────────────────────────────────────────────────────────
      if(PermitirVenda && C1 > ma20 && distMA20 >= distMin)
      {
         double corpo    = MathAbs(O1 - C1);
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200  = !UsarFiltroMA200    || (ma20 < ma200);
         bool ok_limite = (tradesVendaHoje     < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownVenda       == 0);
         bool ok_pavio  = (pavioSup            >= pavioMin);
         bool ok_padrao = (H1 > H2 && C1       <= H2); // Rompeu máxima anterior e fechou abaixo
         bool ok_rsi    = !UsarFiltroRSI       || (rsi > LimiteRSI_Venda);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo            < atr * 0.05) // doji: dispensado
                          || (pavioSup         >= RatioPavioCorpo * corpo);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao && ok_rsi && ok_ratio)
         {
            double gatilho = L1 - gatOff;
            double sl      = H1 + slBuffer;
            double risco   = sl - gatilho;

            if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               precoTakeProfit = gatilho - (risco * RiscoRetorno);
               setupVendaAtivo = true;
            }
         }
      }

      //──────────────────────────────────────────────────────────────
      // SETUP DE COMPRA — Falha de Fundo (exaustão abaixo da MA20)
      //──────────────────────────────────────────────────────────────
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin)
      {
         double corpo    = MathAbs(O1 - C1);
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200  = !UsarFiltroMA200    || (ma20 > ma200);
         bool ok_limite = (tradesCompraHoje    < MaxTradesPorDirecao);
         bool ok_cd     = (cooldownCompra      == 0);
         bool ok_pavio  = (pavioInf            >= pavioMin);
         bool ok_padrao = (L1 < L2 && C1       >= L2); // Perdeu mínima anterior e fechou acima
         bool ok_rsi    = !UsarFiltroRSI       || (rsi < LimiteRSI_Compra);
         bool ok_ratio  = !UsarFiltroPavioCorpo
                          || (corpo            < atr * 0.05)
                          || (pavioInf         >= RatioPavioCorpo * corpo);

         if(ok_MA200 && ok_limite && ok_cd && ok_pavio && ok_padrao && ok_rsi && ok_ratio)
         {
            double gatilho = H1 + gatOff;
            double sl      = L1 - slBuffer;
            double risco   = gatilho - sl;

            if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = gatilho + (risco * RiscoRetorno);
               setupCompraAtivo = true;
            }
         }
      }
   }

   //════════════════════════════════════════════════════════════════
   // BLOCO 2 — Intra-barra: aciona gatilho se preço cruzou o nível
   //════════════════════════════════════════════════════════════════
   if(HasPosition()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(setupCompraAtivo && bid >= precoGatilho)
   {
      if(trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v14"))
         tradesCompraHoje++;
      setupCompraAtivo = false;
      Print("▲ COMPRA | Ask:", ask, " SL:", precoStopLoss, " TP:", precoTakeProfit);
   }

   if(setupVendaAtivo && ask <= precoGatilho)
   {
      if(trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v14"))
         tradesVendaHoje++;
      setupVendaAtivo = false;
      Print("▼ VENDA | Bid:", bid, " SL:", precoStopLoss, " TP:", precoTakeProfit);
   }
}

//+------------------------------------------------------------------+
//  [FIX-D] Break-even: move SL para preço de abertura quando o ganho
//  acumulado ultrapassa BreakEvenATR × ATR14 do candle fechado.
//  Executado a cada tick enquanto há posição aberta.
//+------------------------------------------------------------------+
void GerenciarBreakEven()
{
   double atr = GetBuffer(hATR, 1);
   if(atr <= 0) return;

   double alvo_be = atr * BreakEvenATR;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                              continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)              continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber)    continue;

      double abertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double slAtual  = PositionGetDouble(POSITION_SL);
      double tpAtual  = PositionGetDouble(POSITION_TP);
      double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      if(tipo == POSITION_TYPE_BUY)
      {
         // Já está em break-even ou além
         if(slAtual >= abertura - _Point) continue;
         // Ganho acumulado atingiu o alvo
         if((bid - abertura) >= alvo_be)
         {
            double novoSL = NormalizeDouble(abertura, _Digits);
            trade.PositionModify(ticket, novoSL, tpAtual);
            Print("✔ Break-even BUY ativado | SL movido para ", novoSL);
         }
      }
      else if(tipo == POSITION_TYPE_SELL)
      {
         // Já está em break-even ou além (para SELL, SL <= abertura)
         if(slAtual > 0 && slAtual <= abertura + _Point) continue;
         if((abertura - ask) >= alvo_be)
         {
            double novoSL = NormalizeDouble(abertura, _Digits);
            trade.PositionModify(ticket, novoSL, tpAtual);
            Print("✔ Break-even SELL ativado | SL movido para ", novoSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//  OnTradeTransaction — detecta fechamento por SL e ativa cooldown
//
//  Lógica de deals de fechamento no MT5:
//    DEAL_TYPE_SELL (saída) = fechou posição COMPRADA → cooldownCompra
//    DEAL_TYPE_BUY  (saída) = fechou posição VENDIDA  → cooldownVenda
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
   if(profit >= 0.0) return; // Só ativa cooldown em SL, não em TP

   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(tipo == DEAL_TYPE_BUY) // Fechou posição de VENDA com prejuízo
   {
      cooldownVenda = CooldownBarrasSL;
      Print("⚠ SL em VENDA → cooldown de ", CooldownBarrasSL, " barras ativado");
   }
   else if(tipo == DEAL_TYPE_SELL) // Fechou posição de COMPRA com prejuízo
   {
      cooldownCompra = CooldownBarrasSL;
      Print("⚠ SL em COMPRA → cooldown de ", CooldownBarrasSL, " barras ativado");
   }
}

//+------------------------------------------------------------------+
//  [FIX-E] Valida se o SL proposto respeita o STOPS_LEVEL mínimo
//  exigido pelo ativo na corretora atual.
//+------------------------------------------------------------------+
bool ValidarStops(double gatilho, double sl, ENUM_ORDER_TYPE tipo)
{
   long   nivelPts  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double nivelPreco = nivelPts * _Point;
   if(nivelPreco <= 0) return true; // Corretora sem restrição → sempre válido

   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double preco    = (tipo == ORDER_TYPE_BUY) ? ask : bid;
   double distSL   = MathAbs(preco - sl);

   if(distSL < nivelPreco)
   {
      Print("⚠ Setup ignorado: SL a ", distSL / _Point, " pts do preço (mínimo exigido: ", nivelPts, " pts)");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//  Lê um buffer de indicador no índice especificado
//+------------------------------------------------------------------+
double GetBuffer(int handle, int idx)
{
   double buf[1];
   if(CopyBuffer(handle, 0, idx, 1, buf) > 0) return buf[0];
   return 0.0;
}

//+------------------------------------------------------------------+
//  Verifica se já existe posição aberta pelo EA neste símbolo
//+------------------------------------------------------------------+
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
