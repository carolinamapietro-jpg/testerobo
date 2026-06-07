//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v40.0                      |
//|  Falha Simples+Dupla | BUY uptrend + SELL downtrend real         |
//|  Meta: >4%/mes | USDJPY M5                                        |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v39 (232 trades, 2025.01-2026.06):
//  - Lucro Liquido: -2.400 EUR | PF: 0.92 | Max DD: 67.14%
//  - BUY:  160 trades, 40.0% win rate => EV positivo, mas volume baixo
//  - SELL:  72 trades, 23.6% win rate => -5.127 EUR (destruiu tudo)
//  - Fev/2025: 29 SELL trades, 27.6% win rate em um unico mes
//
//  ANALISE CAUSA RAIZ v39:
//
//  [1] CASO D (SELL uptrend contra) foi o maior erro:
//      Vendia quando MA20>MA200 (bull market!) + C1<MA50(D1)
//      Durante correcao de Jan-Abr/2025, MA50 diario era ~155
//      Price caiu para 148-154 => C1 < MA50(D1) liberou SELL
//      Resultado: dezenas de SELL no meio do bull market => perda total
//
//  [2] CASO C (SELL downtrend M5) sensivel demais:
//      MA20 M5 cruza MA200 em poucas horas => ja libera SELL
//      Durante correcao de 2 semanas, MA20 < MA200 em M5 quase sempre
//      Mas mercado whipsawing => SL hit na maioria das entradas
//
//  [3] Filtro H4 uptrend cortou 45% das entradas BUY:
//      v31: 17 trades BUY/mes | v39: 9.4 BUY/mes
//      Apesar de 40% win rate (vs 38.33% v31), volume menor = menos lucro
//
//  CORRECOES v40:
//
//  [1] REMOVER CASO D completamente — SELL nunca em uptrend
//
//  [2] REMOVER CASO B completamente — sem compra contra-tendencia
//
//  [3] SELL (CASO C) com filtro de gap MA obrigatorio:
//      Novo parametro MinGapMA_ATR = 2.0
//      Condicao: (ma200 - ma20) >= atr * MinGapMA_ATR
//      Efeito: MA200 precisa estar 2xATR ACIMA da MA20
//      Correcao de 2 semanas: MA200>MA20 por apenas 0.1-0.5xATR => SELL BLOQUEADO
//      Bear market real (meses de queda): MA200>MA20 por 2-4xATR => SELL LIBERADO
//      Resultado esperado: 0-2 SELL/mes em bull market, 8-12/mes em bear real
//
//  [4] REMOVER filtro H4 para BUY — restaura volume do v31:
//      v31 (sem H4 filter): 17 BUY/mes @ 38.33% win rate => +477 EUR/mes @ 4.0 lots
//      v39 (com H4 filter): 9.4 BUY/mes @ 40% win rate => ~285 EUR/mes
//      Sem H4 para BUY: ~17 BUY/mes @ ~40% win rate => ~450 EUR/mes @ 3.5 lots
//      H4 filter mantido APENAS para SELL (ajuda confirmar downtrend)
//
//  [5] Falha Dupla para BUY mantida com MinAfastamentoDuplaATR = 1.4:
//      Gera ~3-5 trades BUY extras/mes em padroes de exaustao forte
//      Para SELL: usar mesma distancia que simples (1.7x) — sem relaxacao
//
//  PROJECAO v40 (@ 3.5 lots em 10K EUR):
//  BUY uptrend simples+duplo: ~17-20 trades/mes @ ~40% win rate
//  SELL downtrend real:        ~0-3 trades/mes (apenas bear markets reais)
//  Total esperado: 420-480 EUR/mes = 4.2-4.8% em conta 10K
//  Max DD esperado: ~35% (similar a v33)
//
//  POR QUE O SELL FALHOU EM 2025-2026:
//  USDJPY em alta estrutural. Correcoes de 2 semanas geram MA20<MA200 em M5
//  mas sao apenas pullbacks no bull market. Com MinGapMA=2.0, so um downtrend
//  de semanas a meses faria MA200 estar 2xATR acima da MA20.
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "40.00"
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
input bool   PermitirVenda           = true;    // SELL so dispara em downtrend real (MinGapMA_ATR)

input group "=== PARAMETROS DE OPERACAO ==="
input double LoteInicial             = 3.5;    // 3.5 lots => ~4.3%/mes, DD~35%
input double RiscoRetorno            = 2.0;

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 1.7;    // Dist minima para falha simples; floor: 1.5
input double MinAfastamentoDuplaATR  = 1.4;    // Dist minima para falha dupla BUY; floor: 1.2
                                               // So para BUY — gera trades extras em padroes fortes
input double PavioMinimoATR          = 0.25;
input double SL_Folga_ATR            = 0.2;    // Floor: 0.1 — TP alinha ABAIXO da MA20 (fix v29)
input double MaxSLDistanciaATR       = 2.5;    // Cancela velas outlier; 0 = desabilitado

input group "=== FILTRO SELL — DOWNTREND REAL ==="
input double MinGapMA_ATR            = 2.0;    // Gap minimo (ma200-ma20) em xATR para SELL
                                               // 2.0 = MA200 precisa estar 2xATR acima da MA20
                                               // Bloqueia correcoes curtas (pullbacks no bull market)
                                               // Libera apenas downtrends reais de semanas/meses
                                               // 0 = desabilitado (comportamento v39)

input group "=== FILTRO DIARIO PARA VENDA ==="
input bool   UsarFiltroMaDiaria      = true;
input int    MA_Diaria_Period         = 50;    // SELL so opera se C1 < MA50(D1)

input group "=== FILTRO H4 — APENAS PARA SELL ==="
input bool   UsarFiltroH4Sell        = true;   // H4 filter aplicado SOMENTE ao SELL
input int    MA_H4_Period             = 50;    // MA50 H4
input int    SlopeH4_Barras          = 10;    // 10 barras H4 = ~40 horas

input group "=== FILTRO DE REGIME DE VOLATILIDADE ==="
input bool   UsarFiltroVolatilidade  = true;
input int    ATR_Longo_Periodo       = 100;
input double MaxRazaoATR             = 1.8;    // ATR(14)/ATR(100) > 1.8 = crise => skip

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;
input double SaidaDinamicaMinRR      = 2.0;

input group "=== FILTRO DE MEDIAS M5 ==="
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
int hMA200, hMA20, hATR, hATR_Longo, hMA_H4, hMA_D1;

//==================================================================
//  FLOORS
//==================================================================
double gMinAfastamentoATR;
double gMinAfastamentoDuplaATR;
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

   gMinAfastamentoATR     = MathMax(MinAfastamentoATR,     1.5);
   gMinAfastamentoDuplaATR = MathMax(MinAfastamentoDuplaATR, 1.2);
   gSL_Folga_ATR          = MathMax(SL_Folga_ATR,          0.1);

   if(gMinAfastamentoATR     != MinAfastamentoATR)
      Print("AVISO v40: MinAfastamentoATR elevado ao floor de ", gMinAfastamentoATR);
   if(gMinAfastamentoDuplaATR != MinAfastamentoDuplaATR)
      Print("AVISO v40: MinAfastamentoDuplaATR elevado ao floor de ", gMinAfastamentoDuplaATR);
   if(gSL_Folga_ATR          != SL_Folga_ATR)
      Print("AVISO v40: SL_Folga_ATR elevado ao floor de ", gSL_Folga_ATR);

   double perda_est = 5.07 * LoteInicial / 0.1;
   double lucro_est = 12.0 * LoteInicial / 0.1;

   Print("v40 BUY+SELL | Lote:", LoteInicial,
         " | Perda media estimada: ~", NormalizeDouble(perda_est, 0), " EUR (",
         NormalizeDouble(perda_est / 100.0, 1), "% de 10K)",
         " | Lucro mensal estimado: ~", NormalizeDouble(lucro_est, 0), " EUR (",
         NormalizeDouble(lucro_est / 100.0, 1), "% de 10K)");
   Print("v40 | MinAfastATR:", gMinAfastamentoATR,
         " DuplaATR(BUY):", gMinAfastamentoDuplaATR,
         " MaxSLDist:", MaxSLDistanciaATR,
         " | GapMA(SELL):", MinGapMA_ATR,
         " FiltroVol:", (UsarFiltroVolatilidade ? "ON" : "OFF"),
         " H4sell:", (UsarFiltroH4Sell ? "ON" : "OFF"),
         " D1:", (UsarFiltroMaDiaria ? "ON" : "OFF"),
         " | Cooldown:", CooldownBarrasSL);
   Print("v40 | H4 filter: BUY=REMOVIDO (restaura volume v31) | SELL=", (UsarFiltroH4Sell ? "ON" : "OFF"));

   hMA200     = iMA  (_Symbol, _Period,   MA200_Period,     0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period,   MA20_Period,      0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period,   ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period,   ATR_Longo_Periodo);
   hMA_H4     = iMA  (_Symbol, PERIOD_H4, MA_H4_Period,    0, MODE_SMA, PRICE_CLOSE);
   hMA_D1     = iMA  (_Symbol, PERIOD_D1, MA_Diaria_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(hMA200     == INVALID_HANDLE || hMA20      == INVALID_HANDLE ||
      hATR       == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE ||
      hMA_H4     == INVALID_HANDLE || hMA_D1     == INVALID_HANDLE)
   {
      Print("ERRO v40: falha ao criar handle de indicador.");
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
   IndicatorRelease(hMA_H4);
   IndicatorRelease(hMA_D1);
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

      // --- FILTRO DE REGIME DE VOLATILIDADE (v35) ---
      // Bloqueia periodos de crise/intervencao BOJ: ATR(14) > 1.8x ATR(100)
      if(UsarFiltroVolatilidade && MaxRazaoATR > 0 && atr_longo > 0)
      {
         if(atr / atr_longo > MaxRazaoATR)
         {
            Print("REGIME BLOQUEADO: razao ATR=",
                  NormalizeDouble(atr / atr_longo, 2), " > ", MaxRazaoATR);
            return;
         }
      }

      // --- FILTROS EXCLUSIVOS PARA SELL ---
      // H4 trend: SELL so opera se H4 em tendencia de baixa
      double ma_h4_now = GetBuffer(hMA_H4, 1);
      double ma_h4_old = GetBuffer(hMA_H4, 1 + SlopeH4_Barras);
      bool h4_baixa_ok_sell = !UsarFiltroH4Sell ||
                              (ma_h4_now <= 0) || (ma_h4_old <= 0) ||
                              (ma_h4_now <= ma_h4_old);

      // Daily MA50: SELL so opera se preco abaixo da MA50 diaria
      double ma_d1 = GetBuffer(hMA_D1, 1);
      double C1    = iClose(_Symbol, _Period, 1);
      bool ok_sell_diario = !UsarFiltroMaDiaria || (ma_d1 <= 0) || (C1 < ma_d1);

      // Gap MA: SELL so opera se MA200 > MA20 por pelo menos MinGapMA_ATR * ATR
      // Filtra correcoes curtas (pullbacks no bull market) — permite apenas downtrends reais
      bool ok_sell_gap = (MinGapMA_ATR <= 0) || (ma200 - ma20 >= atr * MinGapMA_ATR);

      // --- DADOS DOS CANDLES ---
      double H1 = iHigh (_Symbol, _Period, 1);
      double L1 = iLow  (_Symbol, _Period, 1);
      double O1 = iOpen (_Symbol, _Period, 1);
      double H2 = iHigh (_Symbol, _Period, 2);
      double L2 = iLow  (_Symbol, _Period, 2);
      double H3 = iHigh (_Symbol, _Period, 3);
      double L3 = iLow  (_Symbol, _Period, 3);
      double C2 = iClose(_Symbol, _Period, 2);

      double distMA20   = MathAbs(C1 - ma20);
      double pavioMin   = atr * PavioMinimoATR;
      double slBuffer   = atr * gSL_Folga_ATR;
      double gatOff     = atr * 0.08;
      double maxRisco   = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;
      double distNormal = atr * gMinAfastamentoATR;
      double distDupla  = atr * gMinAfastamentoDuplaATR;

      lastATR = atr;

      // --- PADROES DE FALHA ---
      // Falha simples: candle 1 rompeu mas fechou de volta
      bool buy_simple  = (L1 < L2 && C1 >= L2);
      bool sell_simple = (H1 > H2 && C1 <= H2);

      // Falha dupla: dois candles consecutivos falharam individualmente
      // Candle 2 E candle 1 ambos tentaram e ambos reverteram
      bool buy_double  = (L2 < L3 && C2 >= L3 && L1 < L2 && C1 >= L2);
      bool sell_double = (H2 > H3 && C2 <= H3 && H1 > H2 && C1 <= H2);

      // Desambiguacao: candle ambiguo (tanto bull quanto bear) => prioridade pelo fechamento
      bool ok_cs = buy_simple  && (!sell_simple || C1 > O1);
      bool ok_cd = buy_double  && (!sell_double || C1 > O1);
      bool ok_vs = sell_simple && (!buy_simple  || C1 < O1);
      bool ok_vd = sell_double && (!buy_double  || C1 < O1);

      // ============================================================
      // SETUP DE COMPRA — BUY uptrend (CASO A)
      // Base provada: v31 = 38.33% WR | v33 = 40% WR | +4.17%/mes
      // H4 filter REMOVIDO para restaurar volume do v31
      // Simples: dist >= 1.7xATR | Dupla: dist >= 1.4xATR (sinal mais forte)
      // ============================================================
      if(PermitirCompra && C1 < ma20 && cooldownCompra == 0)
      {
         bool uptrend    = !UsarFiltroMA200 || (ma20 > ma200);
         double pavioInf = MathMin(O1, C1) - L1;

         if(uptrend && pavioInf >= pavioMin)
         {
            bool ok_simples = ok_cs && (distMA20 >= distNormal);
            bool ok_dupla   = ok_cd && (distMA20 >= distDupla);

            if(ok_simples || ok_dupla)
            {
               double gatilho = H1 + gatOff;
               double sl      = NormalizeDouble(L1 - slBuffer, _Digits);
               double risco   = gatilho - sl;
               double tp      = (RiscoRetorno > 0)
                                ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                                : 0.0;

               bool ok_sl = (maxRisco <= 0) || (risco <= maxRisco);

               if(!ok_sl)
               {
                  Print("COMPRA ignorada (SL teto): ",
                        NormalizeDouble(risco/atr, 2), "xATR > ", MaxSLDistanciaATR);
               }
               else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
               {
                  precoGatilho     = gatilho;
                  precoStopLoss    = sl;
                  precoTakeProfit  = tp;
                  setupCompraAtivo = true;

                  string tipo_str = ok_dupla ? "DUPLA" : "SIMPLES";
                  Print("SETUP COMPRA ", tipo_str,
                        " | SL:", sl, " TP:", tp,
                        " risco:", NormalizeDouble(risco/atr, 2), "xATR",
                        " distMA20:", NormalizeDouble(distMA20/atr, 2), "xATR",
                        " MA20:", NormalizeDouble(ma20, 3),
                        " MA200:", NormalizeDouble(ma200, 3));
               }
            }
         }
      }

      // ============================================================
      // SETUP DE VENDA — SELL downtrend real (CASO C)
      // Espelho do BUY: C1 < MA20 em downtrend confirmado
      // Filtros acumulados:
      //   1) MA20 < MA200 (downtrend M5)
      //   2) Gap MA200-MA20 >= 2.0xATR (downtrend real, nao pullback)
      //   3) H4 em baixa (MA50 H4 declinando)
      //   4) C1 < MA50(D1) (bear market estrutural no diario)
      //   5) Distancia mesma que simples — sem relaxacao para dupla
      // ============================================================
      if(PermitirVenda && C1 < ma20 && cooldownVenda == 0)
      {
         bool downtrend   = !UsarFiltroMA200 || (ma20 < ma200);
         double pavioSup  = H1 - MathMax(O1, C1);

         bool ok_all_sell = downtrend && ok_sell_gap && h4_baixa_ok_sell && ok_sell_diario;

         if(ok_all_sell && pavioSup >= pavioMin)
         {
            bool ok_simples = ok_vs && (distMA20 >= distNormal);
            bool ok_dupla   = ok_vd && (distMA20 >= distNormal);  // mesma distancia para SELL

            if(ok_simples || ok_dupla)
            {
               double gatilho = L1 - gatOff;
               double sl      = NormalizeDouble(H1 + slBuffer, _Digits);
               double risco   = sl - gatilho;
               double tp      = (RiscoRetorno > 0)
                                ? NormalizeDouble(gatilho - risco * RiscoRetorno, _Digits)
                                : 0.0;

               bool ok_sl = (maxRisco <= 0) || (risco <= maxRisco);

               if(!ok_sl)
               {
                  Print("VENDA ignorada (SL teto): ",
                        NormalizeDouble(risco/atr, 2), "xATR > ", MaxSLDistanciaATR);
               }
               else if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
               {
                  precoGatilho    = gatilho;
                  precoStopLoss   = sl;
                  precoTakeProfit = tp;
                  setupVendaAtivo = true;

                  string tipo_str = ok_dupla ? "DUPLA" : "SIMPLES";
                  Print("SETUP VENDA ", tipo_str,
                        " | SL:", sl, " TP:", tp,
                        " risco:", NormalizeDouble(risco/atr, 2), "xATR",
                        " distMA20:", NormalizeDouble(distMA20/atr, 2), "xATR",
                        " gap MA200-MA20:", NormalizeDouble((ma200-ma20)/atr, 2), "xATR",
                        " MA50H4:", NormalizeDouble(ma_h4_now, 3));
               }
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
         trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha Fundo v40");
         Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss, " TP:", precoTakeProfit);
      }
      else
         Print("COMPRA cancelada (anti-gap): ", DoubleToString(overshoot/lastATR, 2), "xATR");
      setupCompraAtivo = false;
   }

   if(setupVendaAtivo && bid <= precoGatilho)
   {
      double overshoot = precoGatilho - bid;
      if(maxGap <= 0 || overshoot <= maxGap)
      {
         trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha Topo v40");
         Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss, " TP:", precoTakeProfit);
      }
      else
         Print("VENDA cancelada (anti-gap): ", DoubleToString(overshoot/lastATR, 2), "xATR");
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

   // Fechar posicao comprada gera deal SELL => cooldown BUY
   if(tipo == DEAL_TYPE_SELL)
   {
      cooldownCompra = CooldownBarrasSL;
      Print("COOLDOWN COMPRA: ", CooldownBarrasSL, " barras apos loss BUY");
   }
   // Fechar posicao vendida gera deal BUY => cooldown SELL
   else if(tipo == DEAL_TYPE_BUY)
   {
      cooldownVenda = CooldownBarrasSL;
      Print("COOLDOWN VENDA: ", CooldownBarrasSL, " barras apos loss SELL");
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
