//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v39.0                      |
//|  Falha Simples+Dupla | BUY+SELL | Alta+Baixa | Sem trava diaria  |
//|  Meta: >4%/mes | USDJPY M5                                        |
//+------------------------------------------------------------------+
//
//  CONSOLIDACAO v29 -> v38 (melhores elementos de cada versao):
//
//  v29: SL_Folga=0.2 [FIX CRITICO] — TP alinha ABAIXO da MA20
//       BUY: 36.63% win rate | PF 1.15+
//  v31: MinAfasto=1.7 | Lote=4.0 | Cooldown=3
//       BUY: 38.33% win rate | PF 1.23 | +477 EUR/mes @ 4.0 lots
//  v33: Slope M5 removido (bloqueava em correcoes)
//       3.5 lots => 4.17%/mes | DD ~35%
//  v34: MaxSLDistanciaATR=2.5 (elimina velas de pavio extremo)
//       Win rate subiu para 47.62% | PF 2.01 | DD caiu de 40% -> 15%
//  v35: FiltroVolatilidade ATR(14)/ATR(100) > 1.8 => skip
//       Protege contra intervencoes BOJ e crises extremas
//  v36: Filtro tendencia H4 (MA50 slope) + SELL ativado simetricamente
//  v38: SELL: preco ABAIXO da MA20 (espelho do BUY) + Filtro MA50 Diario
//       SELL so opera quando C1 < MA50(D1): bear market estrutural real
//
//  INOVACOES v39 — FALHA DUPLA + BIDIREC IONAL COMPLETO:
//
//  [1] FALHA DUPLA DE FUNDO (buy_double):
//      Candle 2: L2 < L3 E C2 >= L3 (primeira falha individual)
//      Candle 1: L1 < L2 E C1 >= L2 (segunda falha individual)
//      Dois candles consecutivos absorveram toda a pressao vendedora.
//      Win rate estimado 42-48% vs 38% da falha simples.
//
//  [2] FALHA DUPLA DE TOPO (sell_double):
//      Candle 2: H2 > H3 E C2 <= H3 (primeira falha individual)
//      Candle 1: H1 > H2 E C1 <= H2 (segunda falha individual)
//      Dois candles consecutivos absorveram toda a pressao compradora.
//
//  [3] QUATRO MODOS DE OPERACAO:
//      A) BUY uptrend (MA20>MA200): simples+duplo, dist>=1.7xATR
//      B) BUY downtrend contra (MA20<MA200): SO duplo, dist>=2.5xATR
//      C) SELL downtrend (MA20<MA200): simples+duplo, dist>=1.7xATR
//      D) SELL uptrend contra (MA20>MA200): SO duplo, dist>=2.5xATR
//         (requer C1<MA50 Diario para confirmar pressao de baixa real)
//
//  [4] Sem trava diaria — opera TODAS as oportunidades qualificadas
//
//  [5] Falha dupla com distancia reduzida (1.4xATR vs 1.7xATR):
//      Sinal mais forte compensa distancia menor da MA20.
//      Gera trades adicionais sem relaxar a qualidade do setup.
//
//  PROJECAO v39 (conservadora @ 3.5 lots em 10K EUR):
//  Modo A (BUY uptrend simples+duplo):  ~18-22 trades/mes x 42%
//  Modo C (SELL downtrend simples+duplo): +6-10 trades/mes x 40%
//  Modos B+D (contra-tendencia duplos):  +4-6 trades/mes x 44%
//  Total estimado: 480-580 EUR/mes = 4.8-5.8% em conta 10K
//  MaxDD estimado: ~35-40% (similar ao v33/v34)
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "39.00"
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
input double LoteInicial             = 3.5;    // 3.5 lots => ~4.5%/mes, DD~37%
                                               // 4.0 lots => ~5.0%/mes, DD~42%
input double RiscoRetorno            = 2.0;    // 0 = sem TP fixo (usa so saida dinamica)

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 1.7;    // Dist minima p/ falha simples; floor: 1.5
input double MinAfastamentoDuplaATR  = 1.4;    // Dist minima p/ falha dupla; floor: 1.2
                                               // Mais baixo: sinal duplo compensa dist menor
input double MinAfastamentoContraATR = 2.5;    // Dist p/ contra-tendencia (duplo obrigatorio); floor: 2.0
input double PavioMinimoATR          = 0.25;   // Pavio minimo do candle de sinal
input double SL_Folga_ATR            = 0.2;    // Buffer SL alem do pavio; floor: 0.1
                                               // Critico (v29 fix): TP alinha ABAIXO da MA20
input double MaxSLDistanciaATR       = 2.5;    // Cancela se risco > 2.5xATR (velas outlier)
                                               // 0 = desabilitado

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 15;
input double SaidaDinamicaMinRR      = 2.0;

input group "=== FILTRO DE MEDIAS M5 ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;   // Regime adaptativo BUY/SELL

input group "=== FILTRO DIARIO PARA VENDA ==="
input bool   UsarFiltroMaDiaria      = true;
input int    MA_Diaria_Period         = 50;     // SELL so opera se C1 < MA50(D1)
                                               // Garante venda apenas em bear market real
                                               // Bloqueia SELL em bull markets estruturais

input group "=== FILTRO DE TENDENCIA H4 ==="
input bool   UsarFiltroTendenciaH4   = true;
input int    MA_H4_Period             = 50;
input int    SlopeH4_Barras          = 10;     // MA_H4[1] vs MA_H4[1+N]: 10x H4 = ~40 horas

input group "=== FILTRO DE REGIME DE VOLATILIDADE ==="
input bool   UsarFiltroVolatilidade  = true;
input int    ATR_Longo_Periodo       = 100;
input double MaxRazaoATR             = 1.8;    // ATR(14)/ATR(100) > 1.8 = crise/BOJ => skip

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
double gMinAfastamentoContraATR;
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

   gMinAfastamentoATR      = MathMax(MinAfastamentoATR,      1.5);
   gMinAfastamentoDuplaATR  = MathMax(MinAfastamentoDuplaATR,  1.2);
   gMinAfastamentoContraATR = MathMax(MinAfastamentoContraATR, 2.0);
   gSL_Folga_ATR           = MathMax(SL_Folga_ATR,           0.1);

   if(gMinAfastamentoATR      != MinAfastamentoATR)
      Print("AVISO v39: MinAfastamentoATR elevado ao floor de ",      gMinAfastamentoATR);
   if(gMinAfastamentoDuplaATR  != MinAfastamentoDuplaATR)
      Print("AVISO v39: MinAfastamentoDuplaATR elevado ao floor de ",  gMinAfastamentoDuplaATR);
   if(gMinAfastamentoContraATR != MinAfastamentoContraATR)
      Print("AVISO v39: MinAfastamentoContraATR elevado ao floor de ", gMinAfastamentoContraATR);
   if(gSL_Folga_ATR           != SL_Folga_ATR)
      Print("AVISO v39: SL_Folga_ATR elevado ao floor de ",           gSL_Folga_ATR);

   double perda_est = 5.07 * LoteInicial / 0.1;
   double lucro_est = 13.0 * LoteInicial / 0.1;

   Print("v39 BUY+SELL Simples+Duplo | Lote:", LoteInicial,
         " | Perda media estimada: ~", NormalizeDouble(perda_est, 0), " EUR (",
         NormalizeDouble(perda_est / 100.0, 1), "% de 10K)",
         " | Lucro mensal estimado: ~", NormalizeDouble(lucro_est, 0), " EUR (",
         NormalizeDouble(lucro_est / 100.0, 1), "% de 10K)");
   Print("v39 | MinAfastATR:", gMinAfastamentoATR,
         " DuplaATR:", gMinAfastamentoDuplaATR,
         " ContraATR:", gMinAfastamentoContraATR,
         " MaxSLDist:", MaxSLDistanciaATR,
         " | FiltroMA200:", (UsarFiltroMA200 ? "ON" : "OFF"),
         " H4:", (UsarFiltroTendenciaH4 ? "ON" : "OFF"),
         " Vol:", (UsarFiltroVolatilidade ? "ON" : "OFF"),
         " D1:", (UsarFiltroMaDiaria ? "ON" : "OFF"),
         " | Cooldown:", CooldownBarrasSL);

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
      Print("ERRO v39: falha ao criar handle de indicador.");
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
      if(UsarFiltroVolatilidade && MaxRazaoATR > 0 && atr_longo > 0)
      {
         if(atr / atr_longo > MaxRazaoATR)
         {
            Print("REGIME BLOQUEADO: razao ATR=",
                  NormalizeDouble(atr / atr_longo, 2), " > ", MaxRazaoATR);
            return;
         }
      }

      // --- FILTRO TENDENCIA H4 (v36) ---
      double ma_h4_now = GetBuffer(hMA_H4, 1);
      double ma_h4_old = GetBuffer(hMA_H4, 1 + SlopeH4_Barras);

      bool h4_uptrend   = !UsarFiltroTendenciaH4 || (ma_h4_now <= 0) || (ma_h4_old <= 0)
                          || (ma_h4_now >= ma_h4_old);
      bool h4_downtrend = !UsarFiltroTendenciaH4 || (ma_h4_now <= 0) || (ma_h4_old <= 0)
                          || (ma_h4_now <= ma_h4_old);

      // --- FILTRO DAILY MA50 PARA SELL (v38) ---
      double ma_d1 = GetBuffer(hMA_D1, 1);
      bool ok_sell_diario = !UsarFiltroMaDiaria || (ma_d1 <= 0) || (iClose(_Symbol, _Period, 1) < ma_d1);

      // --- DADOS DOS CANDLES ---
      double C1 = iClose(_Symbol, _Period, 1);
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
      double distContra = atr * gMinAfastamentoContraATR;

      lastATR = atr;

      // --- PADROES DE FALHA ---
      // Falha simples: candle 1 tentou romper mas fechou de volta
      bool buy_simple  = (L1 < L2 && C1 >= L2);
      bool sell_simple = (H1 > H2 && C1 <= H2);

      // Falha dupla: dois candles consecutivos falharam individualmente
      // Candle 2 e 1 ambos tentaram romper e ambos fecharam de volta
      bool buy_double  = (L2 < L3 && C2 >= L3 && L1 < L2 && C1 >= L2);
      bool sell_double = (H2 > H3 && C2 <= H3 && H1 > H2 && C1 <= H2);

      // Desambiguacao: candle ambiguo priorizando pelo fechamento
      bool ok_cs = buy_simple  && (!sell_simple || C1 > O1);   // compra simples
      bool ok_cd = buy_double  && (!sell_double || C1 > O1);   // compra dupla
      bool ok_vs = sell_simple && (!buy_simple  || C1 < O1);   // venda simples
      bool ok_vd = sell_double && (!buy_double  || C1 < O1);   // venda dupla

      bool uptrend   = !UsarFiltroMA200 || (ma20 > ma200);
      bool downtrend = !UsarFiltroMA200 || (ma20 < ma200);

      // ============================================================
      // SETUP DE COMPRA — 4 casos
      // ============================================================

      // CASO A: BUY uptrend (C1<MA20, MA20>MA200) — simples + duplo
      //   Preco abaixo da MA20 em mercado de alta: compra o pullback.
      //   Base provada em v31/v33: 38.33% win rate, PF 1.23.

      // CASO B: BUY downtrend contra (C1<MA20, MA20<MA200) — SO duplo
      //   Exaustao de vendedores durante tendencia de baixa.
      //   Sinal mais forte compensa o risco contra-tendencia.

      if(PermitirCompra && C1 < ma20 && cooldownCompra == 0)
      {
         double pavioInf = MathMin(O1, C1) - L1;
         if(pavioInf >= pavioMin)
         {
            bool ok_simples_A = uptrend   && h4_uptrend   && ok_cs && (distMA20 >= distNormal);
            bool ok_dupla_A   = uptrend   && h4_uptrend   && ok_cd && (distMA20 >= distDupla);
            bool ok_dupla_B   = downtrend && h4_downtrend && ok_cd && (distMA20 >= distContra);

            bool deve_entrar = ok_simples_A || ok_dupla_A || ok_dupla_B;

            if(deve_entrar)
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
                        NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
               }
               else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
               {
                  precoGatilho     = gatilho;
                  precoStopLoss    = sl;
                  precoTakeProfit  = tp;
                  setupCompraAtivo = true;

                  string tipo_str = ok_dupla_A ? "DUPLA-up" :
                                    ok_dupla_B ? "DUPLA-contra" : "SIMPLES-up";
                  Print("SETUP COMPRA ", tipo_str,
                        " | SL:", sl, " TP:", tp,
                        " risco:", NormalizeDouble(risco/atr,2), "xATR",
                        " distMA20:", NormalizeDouble(distMA20/atr,2), "xATR",
                        " MA20:", NormalizeDouble(ma20,3),
                        " MA200:", NormalizeDouble(ma200,3));
               }
            }
         }
      }

      // ============================================================
      // SETUP DE VENDA — 4 casos
      // ============================================================

      // CASO C: SELL downtrend espelho (C1<MA20, MA20<MA200) — simples + duplo
      //   Preco abaixo da MA20 em mercado de baixa: vende o pullback.
      //   Espelho exato do BUY uptrend. Requer filtro MA50 Diario.

      // CASO D: SELL uptrend contra (C1>MA20, MA20>MA200) — SO duplo
      //   Exaustao de compradores em topo com MA50 Diario confirmando
      //   pressao vendedora real. Sinal duplo obrigatorio.

      if(PermitirVenda && cooldownVenda == 0)
      {
         // CASO C: espelho do BUY (C1 abaixo da MA20 em downtrend)
         if(C1 < ma20 && downtrend && h4_downtrend && ok_sell_diario)
         {
            double pavioSup = H1 - MathMax(O1, C1);
            if(pavioSup >= pavioMin)
            {
               bool ok_simples_C = ok_vs && (distMA20 >= distNormal);
               bool ok_dupla_C   = ok_vd && (distMA20 >= distDupla);

               if(ok_simples_C || ok_dupla_C)
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
                           NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
                  }
                  else if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
                  {
                     precoGatilho    = gatilho;
                     precoStopLoss   = sl;
                     precoTakeProfit = tp;
                     setupVendaAtivo = true;

                     string tipo_str = ok_dupla_C ? "DUPLA-down" : "SIMPLES-down";
                     Print("SETUP VENDA ", tipo_str,
                           " | SL:", sl, " TP:", tp,
                           " risco:", NormalizeDouble(risco/atr,2), "xATR",
                           " distMA20:", NormalizeDouble(distMA20/atr,2), "xATR",
                           " MA50H4:", NormalizeDouble(ma_h4_now,3));
                  }
               }
            }
         }

         // CASO D: contra-tendencia em uptrend (C1 acima da MA20)
         // Apenas duplo + filtro MA50 Diario obrigatorio
         if(!setupVendaAtivo && C1 > ma20 && uptrend && ok_sell_diario)
         {
            double pavioSup = H1 - MathMax(O1, C1);
            if(pavioSup >= pavioMin && ok_vd && (distMA20 >= distContra))
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
                  Print("VENDA-contra ignorada (SL teto): ",
                        NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
               }
               else if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
               {
                  precoGatilho    = gatilho;
                  precoStopLoss   = sl;
                  precoTakeProfit = tp;
                  setupVendaAtivo = true;
                  Print("SETUP VENDA DUPLA-contra-up",
                        " | SL:", sl, " TP:", tp,
                        " risco:", NormalizeDouble(risco/atr,2), "xATR",
                        " distMA20:", NormalizeDouble(distMA20/atr,2), "xATR");
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
         trade.Buy(LoteInicial, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha Fundo v39");
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
         trade.Sell(LoteInicial, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha Topo v39");
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
