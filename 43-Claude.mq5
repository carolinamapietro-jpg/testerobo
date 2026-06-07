//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v43.0                      |
//|  HA Nativo 2-Barras | BUY-only | Risco Dinamico | USDJPY M5      |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v42 (401 trades, 2025.01-2026.06):
//  - Lucro liquido: -6.475 EUR (PREJUIZO — pior que v41!)
//  - Max DD: 64.76% (catastrofico)
//  - PF: 0.79 | Win rate: 40.9% (necessario: >= 46.8%)
//  - Avg Win: 146 EUR | Avg Loss: 128 EUR (payoff 1.14 — bom)
//  - Tempo min posicao: 0:00:01 (trades fechando em SEGUNDOS)
//
//  POR QUE v42 FALHOU:
//  [A] SL_Folga_ATR=0.15: buffer de 2-3 pips no M5. Tick noise
//      bate o SL em segundos. Ex: trade 19:05:00 fechado 19:05:38.
//  [B] 1 barra de confirmacao: flip unico em M5 e ruidoso demais.
//      59.1% das entradas sao reversoes falsas — win rate insufi-
//      ciente para o payoff 1.14 ser lucrativo.
//  [C] Sem limite de trades por dia: 8 trades em 19/03, 6 em 20/03.
//      Dias ruins destroem o equity com multiplas entradas.
//
//  SOLUCAO v43 — 3 MUDANCAS CIRURGICAS:
//
//  [1] 2 BARRAS DE CONFIRMACAO
//      Sinal: bar[1] verde E bar[2] verde E bar[3] vermelho
//      Dois M5 consecutivos verdes = reversao sustentada, nao ruido
//      => win rate esperado: 52-58% (vs 40.9% no v42)
//
//  [2] SL AMPLIADO: SL_Folga_ATR = 0.5 (era 0.15)
//      SL = min(HA_Low[1], HA_Low[2]) - ATR * 0.5
//      Buffer de 7-10 pips real vs 2-3 pips antes
//      => elimina stops em segundos por tick noise
//      Lote menor compensa o risco EUR por trade constante (1.5%)
//
//  [3] MAX TRADES POR DIA = 2
//      Evita 8 trades em um dia choppy destruindo equity
//      Preserva capital para dias com tendencia real
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "43.00"
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
input bool   PermitirVenda           = false;

input group "=== HEIKIN ASHI ==="
input int    HA_Lookback             = 200;   // Barras para convergencia (>= 100 recomendado)

input group "=== GESTAO DE RISCO DINAMICA ==="
input bool   UsarRiscoDinamico       = true;
input double RiscoPerTrade_PCT       = 1.5;   // % do equity por trade
input double LoteFixo                = 3.5;   // Lote fixo (UsarRiscoDinamico=false)
input double MaxLote                 = 5.0;
input double RiscoRetorno            = 2.0;

input group "=== PARCIAL TP + BREAKEVEN ==="
input bool   UsarParcialTP           = true;
input double ParcialTP_RR            = 1.5;   // fechar 50% ao 1.5x risco, BE
input double ParcialTP_Volume_PCT    = 50.0;

input group "=== CIRCUIT BREAKERS ==="
input double MaxPerdaDiaria_PCT      = 3.0;
input double MaxPerdaSemanal_PCT     = 8.0;
input int    MaxPerdasConsecutivas   = 5;
input int    CooldownPerdasConsec    = 30;
input int    MaxTradesDia            = 2;    // v43: maximo de entradas por dia

input group "=== THRESHOLDS EM ATR ==="
input double SL_Folga_ATR            = 0.5;  // v43: era 0.15 — ampliado para 0.5
input double MaxSLDistanciaATR       = 3.0;
input double MinSLDistanciaATR       = 0.3;
input double MinCorpoHA_ATR          = 0.10; // v43: corpo minimo barra[1] em ATR

input group "=== FILTRO DE TENDENCIA H4 ==="
input bool   UsarFiltroTendenciaH4   = true;
input int    MA_H4_Period             = 50;
input int    SlopeH4_Barras          = 10;

input group "=== FILTRO DE REGIME DE VOLATILIDADE ==="
input bool   UsarFiltroVolatilidade  = true;
input int    ATR_Longo_Periodo       = 100;
input double MaxRazaoATR             = 1.8;

input group "=== SAIDA DINAMICA ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 12;
input double SaidaDinamicaMinRR      = 1.8;

input group "=== FILTRO DE MEDIAS ==="
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
input int    CooldownBarrasSL        = 5;

input group "=== GERAL ==="
input ulong  MagicNumber             = 202409;

//==================================================================
//  HANDLES
//==================================================================
int hMA200, hMA20, hATR, hATR_Longo, hMA_H4;

//==================================================================
//  ESTADO PERSISTENTE
//==================================================================
datetime lastBar         = 0;

bool   setupCompraAtivo  = false;
bool   setupVendaAtivo   = false;
double precoGatilho      = 0.0;
double precoStopLoss     = 0.0;
double precoTakeProfit   = 0.0;
double loteCalculado     = 0.0;
double lastATR           = 0.0;

int    cooldownCompra    = 0;
int    cooldownVenda     = 0;

int      perdasConsecutivas    = 0;
int      cooldownConsecutivo   = 0;
bool     tradingBloqueadoHoje  = false;
bool     tradingBloqueadoSemana= false;
int      tradesDiaContagem     = 0;   // v43: contador de trades do dia
datetime ultimoDiaVerificado   = 0;
datetime ultimaSemanaVerificada= 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   Print("v43 HA 2-Barras | Risco:",
         (UsarRiscoDinamico ? DoubleToString(RiscoPerTrade_PCT,1)+"%" : "fixo "+DoubleToString(LoteFixo,2)),
         " | MaxLote:", MaxLote,
         " | SL_Folga:", SL_Folga_ATR, "xATR",
         " | MaxTradesDia:", MaxTradesDia,
         " | MinCorpo:", MinCorpoHA_ATR, "xATR",
         " | FiltroH4:", (UsarFiltroTendenciaH4 ? "ON" : "OFF"));

   hMA200     = iMA  (_Symbol, _Period,   MA200_Period,    0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period,   MA20_Period,     0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period,   ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period,   ATR_Longo_Periodo);
   hMA_H4     = iMA  (_Symbol, PERIOD_H4, MA_H4_Period,   0, MODE_SMA, PRICE_CLOSE);

   if(hMA200 == INVALID_HANDLE || hMA20      == INVALID_HANDLE ||
      hATR   == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE ||
      hMA_H4 == INVALID_HANDLE)
   {
      Print("ERRO v43: falha ao criar handle de indicador.");
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
}

//+------------------------------------------------------------------+
// Calcula Heikin Ashi para a barra bar_idx com HA_Lookback de aquecimento.
// Formulas padrao: HA_C=(O+H+L+C)/4, HA_O=(prevO+prevC)/2, HA_H/L=max/min
//+------------------------------------------------------------------+
void CalcularHA(int bar_idx,
                double &ha_o, double &ha_h, double &ha_l, double &ha_c)
{
   int start = bar_idx + HA_Lookback;

   double o = iOpen (_Symbol, _Period, start);
   double h = iHigh (_Symbol, _Period, start);
   double l = iLow  (_Symbol, _Period, start);
   double c = iClose(_Symbol, _Period, start);

   double prev_ha_o = (o + c) / 2.0;
   double prev_ha_c = (o + h + l + c) / 4.0;

   for(int i = start - 1; i >= bar_idx; i--)
   {
      o = iOpen (_Symbol, _Period, i);
      h = iHigh (_Symbol, _Period, i);
      l = iLow  (_Symbol, _Period, i);
      c = iClose(_Symbol, _Period, i);

      ha_c = (o + h + l + c) / 4.0;
      ha_o = (prev_ha_o + prev_ha_c) / 2.0;
      ha_h = MathMax(h, MathMax(ha_o, ha_c));
      ha_l = MathMin(l, MathMin(ha_o, ha_c));

      prev_ha_o = ha_o;
      prev_ha_c = ha_c;
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime barAtual = iTime(_Symbol, _Period, 0);

   if(barAtual != lastBar)
   {
      lastBar = barAtual;

      VerificarResetDiario(barAtual);
      VerificarResetSemanal(barAtual);

      if(cooldownCompra      > 0) cooldownCompra--;
      if(cooldownVenda       > 0) cooldownVenda--;
      if(cooldownConsecutivo > 0) cooldownConsecutivo--;

      setupCompraAtivo = false;
      setupVendaAtivo  = false;

      if(HasPosition())
      {
         if(UsarParcialTP)     VerificarParcialEBreakeven();
         if(UsarSaidaDinamica) VerificarSaidaDinamica();
         return;
      }

      if(tradingBloqueadoHoje || tradingBloqueadoSemana || cooldownConsecutivo > 0) return;

      // v43: limite de trades por dia
      if(MaxTradesDia > 0 && tradesDiaContagem >= MaxTradesDia)
      {
         return;
      }

      if(UsarFiltroHorario)
      {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         if(dt.hour < HoraInicio || dt.hour >= HoraFim) return;
      }

      // --- INDICADORES ---
      double ma20      = GetBuffer(hMA20,      1);
      double ma200     = GetBuffer(hMA200,     1);
      double atr       = GetBuffer(hATR,       1);
      double atr_longo = GetBuffer(hATR_Longo, 1);

      if(ma20 <= 0 || atr <= 0) return;
      if(UsarFiltroMA200 && ma200 <= 0) return;

      // --- FILTRO VOLATILIDADE ---
      if(UsarFiltroVolatilidade && MaxRazaoATR > 0 && atr_longo > 0)
      {
         double razao = atr / atr_longo;
         if(razao > MaxRazaoATR)
         {
            Print("REGIME BLOQUEADO: ATR/ATR_longo=", NormalizeDouble(razao,2), " > ", MaxRazaoATR);
            return;
         }
      }

      // --- FILTRO H4 ---
      double ma_h4_now = GetBuffer(hMA_H4, 1);
      double ma_h4_old = GetBuffer(hMA_H4, 1 + SlopeH4_Barras);

      bool tendencia_alta_h4 = !UsarFiltroTendenciaH4 ||
                                (ma_h4_now <= 0) || (ma_h4_old <= 0) ||
                                (ma_h4_now >= ma_h4_old);

      // --- HEIKIN ASHI NATIVO — 3 BARRAS ---
      double ha_o1, ha_h1, ha_l1, ha_c1; // barra [1] — confirmacao
      double ha_o2, ha_h2, ha_l2, ha_c2; // barra [2] — flip
      double ha_o3, ha_h3, ha_l3, ha_c3; // barra [3] — contexto vermelho

      CalcularHA(1, ha_o1, ha_h1, ha_l1, ha_c1);
      CalcularHA(2, ha_o2, ha_h2, ha_l2, ha_c2);
      CalcularHA(3, ha_o3, ha_h3, ha_l3, ha_c3);

      if(ha_o1 <= 0 || ha_c1 <= 0 || ha_l1 <= 0) return;
      if(ha_o2 <= 0 || ha_c2 <= 0) return;

      bool ha_verde_1    = (ha_c1 > ha_o1);   // barra [1]: bullish (verde)
      bool ha_verde_2    = (ha_c2 > ha_o2);   // barra [2]: bullish (verde) — flip
      bool ha_vermelho_3 = (ha_c3 <= ha_o3);  // barra [3]: bearish (vermelho)

      // v43: SINAL COMPRA = 2 barras verdes consecutivas apos vermelho
      bool sinal_compra = ha_verde_1 && ha_verde_2 && ha_vermelho_3;

      // SINAL VENDA (desabilitado por padrao)
      bool ha_vermelho_1 = (ha_c1 < ha_o1);
      bool ha_vermelho_2 = (ha_c2 < ha_o2);
      bool ha_verde_3    = (ha_c3 > ha_o3);
      bool sinal_venda   = ha_vermelho_1 && ha_vermelho_2 && ha_verde_3;

      lastATR = atr;

      // v43: SL usa min dos HA_Low das 2 barras de sinal
      double slBase  = MathMin(ha_l1, ha_l2);
      double slBuffer = atr * SL_Folga_ATR;
      double gatOff   = atr * 0.05;
      double maxRisco = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;
      double minRisco = atr * MinSLDistanciaATR;

      // v43: filtro de corpo minimo na barra de confirmacao [1]
      double corpo1    = ha_c1 - ha_o1;
      bool   ok_corpo1 = (MinCorpoHA_ATR <= 0) || (corpo1 >= MinCorpoHA_ATR * atr);

      //------------------------------------------------------------
      // SETUP DE COMPRA — 2 barras HA verdes apos vermelho
      //------------------------------------------------------------
      if(PermitirCompra && sinal_compra && tendencia_alta_h4 && ok_corpo1)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 > ma200);
         bool ok_cd    = (cooldownCompra == 0);

         if(ok_MA200 && ok_cd)
         {
            double gatilho = ha_c1 + gatOff;
            double sl      = NormalizeDouble(slBase - slBuffer, _Digits);
            double risco   = gatilho - sl;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                             : 0.0;

            bool ok_sl_max = (maxRisco <= 0) || (risco <= maxRisco);
            bool ok_sl_min = (risco >= minRisco);

            if(!ok_sl_max)
               Print("COMPRA ignorada (SL largo): ", NormalizeDouble(risco/atr,2), "xATR");
            else if(!ok_sl_min)
               Print("COMPRA ignorada (SL estreito): ", NormalizeDouble(risco/atr,2), "xATR");
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               loteCalculado    = CalcularLote(gatilho, sl);
               setupCompraAtivo = true;
               Print("SETUP COMPRA (2xHA verde) | SL:", sl,
                     " TP:", tp,
                     " Lote:", loteCalculado,
                     " SLbase:", NormalizeDouble(slBase, _Digits),
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     " corpo:", NormalizeDouble(corpo1/atr,2), "xATR");
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE VENDA (desabilitado por padrao)
      //------------------------------------------------------------
      if(PermitirVenda && sinal_venda && !tendencia_alta_h4)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_cd    = (cooldownVenda == 0);

         if(ok_MA200 && ok_cd)
         {
            double slBaseV  = MathMax(ha_h1, ha_h2);
            double gatilho  = ha_c1 - gatOff;
            double sl       = NormalizeDouble(slBaseV + slBuffer, _Digits);
            double risco    = sl - gatilho;
            double tp       = (RiscoRetorno > 0)
                              ? NormalizeDouble(gatilho - risco * RiscoRetorno, _Digits)
                              : 0.0;

            bool ok_sl_max = (maxRisco <= 0) || (risco <= maxRisco);
            bool ok_sl_min = (risco >= minRisco);

            if(ok_sl_max && ok_sl_min && ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               precoTakeProfit = tp;
               loteCalculado   = CalcularLote(gatilho, sl);
               setupVendaAtivo = true;
               Print("SETUP VENDA (2xHA vermelho) | SL:", sl,
                     " TP:", tp, " Lote:", loteCalculado,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR");
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
         if(loteCalculado <= 0) loteCalculado = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(trade.Buy(loteCalculado, _Symbol, ask, precoStopLoss, precoTakeProfit, "HA v43"))
         {
            tradesDiaContagem++;
            Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss,
                  " TP:", precoTakeProfit, " Lote:", loteCalculado,
                  " TradesDia:", tradesDiaContagem, "/", MaxTradesDia);
         }
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
         if(loteCalculado <= 0) loteCalculado = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(trade.Sell(loteCalculado, _Symbol, bid, precoStopLoss, precoTakeProfit, "HA v43"))
         {
            tradesDiaContagem++;
            Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss,
                  " TP:", precoTakeProfit, " Lote:", loteCalculado);
         }
      }
      else
         Print("VENDA cancelada (anti-gap): ", DoubleToString(overshoot/lastATR,2), "xATR");
      setupVendaAtivo = false;
   }
}

//+------------------------------------------------------------------+
void VerificarParcialEBreakeven()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(tipo != POSITION_TYPE_BUY) continue;

      double abertura   = PositionGetDouble(POSITION_PRICE_OPEN);
      double slPos      = PositionGetDouble(POSITION_SL);
      double tpPos      = PositionGetDouble(POSITION_TP);
      double riscoPreco = abertura - slPos;
      if(riscoPreco <= 0) continue;

      if(slPos >= abertura - _Point * 2) continue;  // BE ja movido

      double nivel = abertura + riscoPreco * ParcialTP_RR;
      if(bid < nivel) continue;

      double newSL = NormalizeDouble(abertura, _Digits);
      trade.PositionModify(ticket, newSL, tpPos);
      Print("BREAKEVEN: SL=", newSL, " | RR=", NormalizeDouble((bid-abertura)/riscoPreco,2));

      double volume    = PositionGetDouble(POSITION_VOLUME);
      double volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double volParcial = MathFloor(volume * ParcialTP_Volume_PCT / 100.0 / volStep) * volStep;
      if(volParcial < volMin) volParcial = volMin;
      if(volParcial >= volume) continue;

      if(trade.PositionClosePartial(ticket, volParcial))
         Print("PARCIAL: fechou ", volParcial, " lotes | restante:",
               NormalizeDouble(volume - volParcial, 2));
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
void VerificarResetDiario(datetime barAtual)
{
   MqlDateTime dt, dtUlt;
   TimeToStruct(barAtual,            dt);
   TimeToStruct(ultimoDiaVerificado, dtUlt);

   bool novoDia = (ultimoDiaVerificado == 0 ||
                   dt.day != dtUlt.day || dt.mon != dtUlt.mon || dt.year != dtUlt.year);
   if(!novoDia) return;

   ultimoDiaVerificado  = barAtual;
   tradingBloqueadoHoje = false;
   tradesDiaContagem    = 0;   // v43: reset contador diario

   if(MaxPerdaDiaria_PCT > 0)
   {
      double perdaHoje   = GetLucroHoje();
      double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
      double limitePerda = equity * MaxPerdaDiaria_PCT / 100.0;
      if(perdaHoje < -limitePerda)
      {
         tradingBloqueadoHoje = true;
         Print("CB DIARIO: perda=", NormalizeDouble(-perdaHoje,2), " EUR > limite=",
               NormalizeDouble(limitePerda,2));
      }
   }
}

//+------------------------------------------------------------------+
void VerificarResetSemanal(datetime barAtual)
{
   if(MaxPerdaSemanal_PCT <= 0) return;

   MqlDateTime dt, dtUlt;
   TimeToStruct(barAtual,               dt);
   TimeToStruct(ultimaSemanaVerificada, dtUlt);

   bool novaSemanaBool = (ultimaSemanaVerificada == 0);
   if(!novaSemanaBool && dt.day_of_week == 1 && dtUlt.day_of_week != 1)
      novaSemanaBool = true;
   if(!novaSemanaBool && (dt.year != dtUlt.year || dt.mon != dtUlt.mon))
      novaSemanaBool = (dt.day_of_week == 1);
   if(!novaSemanaBool) return;

   ultimaSemanaVerificada = barAtual;
   tradingBloqueadoSemana = false;

   double perdaSemana = GetLucroSemana();
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double limite      = equity * MaxPerdaSemanal_PCT / 100.0;
   if(perdaSemana < -limite)
   {
      tradingBloqueadoSemana = true;
      Print("CB SEMANAL: perda=", NormalizeDouble(-perdaSemana,2), " EUR > limite=",
            NormalizeDouble(limite,2));
   }
}

//+------------------------------------------------------------------+
double GetLucroHoje()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime hojeInicio = StructToTime(dt);
   if(!HistorySelect(hojeInicio, TimeCurrent())) return 0.0;

   double total = 0.0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)MagicNumber) continue;
      ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
         total += HistoryDealGetDouble(tk, DEAL_PROFIT);
   }
   return total;
}

//+------------------------------------------------------------------+
double GetLucroSemana()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int diasDesdeSegunda = (dt.day_of_week == 0) ? 6 : (int)dt.day_of_week - 1;
   datetime semanaInicio = TimeCurrent() - (datetime)(diasDesdeSegunda * 86400);
   MqlDateTime ds;
   TimeToStruct(semanaInicio, ds);
   ds.hour = 0; ds.min = 0; ds.sec = 0;
   semanaInicio = StructToTime(ds);

   if(!HistorySelect(semanaInicio, TimeCurrent())) return 0.0;

   double total = 0.0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong tk = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(tk, DEAL_MAGIC) != (long)MagicNumber) continue;
      ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
         total += HistoryDealGetDouble(tk, DEAL_PROFIT);
   }
   return total;
}

//+------------------------------------------------------------------+
double CalcularLote(double gatilho, double sl)
{
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lote;

   if(!UsarRiscoDinamico)
   {
      lote = LoteFixo;
   }
   else
   {
      double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
      double risco    = equity * RiscoPerTrade_PCT / 100.0;
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double ptVal    = (tickSize > 0) ? tickVal / tickSize * _Point : tickVal;
      double slPts    = MathAbs(gatilho - sl) / _Point;

      if(slPts <= 0 || ptVal <= 0)
      {
         Print("AVISO CalcularLote: slPts=", slPts, " ptVal=", ptVal, " -> LoteFixo");
         lote = LoteFixo;
      }
      else
         lote = risco / (slPts * ptVal);
   }

   return MathMax(lotMin, MathMin(MaxLote, MathFloor(lote / lotStep) * lotStep));
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

   if(profit < 0.0)
   {
      perdasConsecutivas++;
      if(MaxPerdasConsecutivas > 0 && perdasConsecutivas >= MaxPerdasConsecutivas)
      {
         cooldownConsecutivo = CooldownPerdasConsec;
         perdasConsecutivas  = 0;
         Print("PAUSA CONSECUTIVA: ", MaxPerdasConsecutivas,
               " perdas -> cooldown ", CooldownPerdasConsec, " barras");
      }

      if(MaxPerdaDiaria_PCT > 0)
      {
         double perdaHoje = GetLucroHoje();
         double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
         if(perdaHoje < -(equity * MaxPerdaDiaria_PCT / 100.0))
         {
            tradingBloqueadoHoje = true;
            Print("CB DIARIO: perda=", NormalizeDouble(-perdaHoje,2), " EUR");
         }
      }

      if(MaxPerdaSemanal_PCT > 0)
      {
         double perdaSemana = GetLucroSemana();
         double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
         if(perdaSemana < -(equity * MaxPerdaSemanal_PCT / 100.0))
         {
            tradingBloqueadoSemana = true;
            Print("CB SEMANAL: perda semana=", NormalizeDouble(-perdaSemana,2), " EUR");
         }
      }
   }
   else
   {
      perdasConsecutivas = 0;
   }

   if(CooldownBarrasSL <= 0 || profit >= 0.0) return;

   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   if(tipo == DEAL_TYPE_SELL)
   {
      cooldownCompra = CooldownBarrasSL;
      Print("COOLDOWN COMPRA: ", CooldownBarrasSL, " barras");
   }
   else if(tipo == DEAL_TYPE_BUY)
   {
      cooldownVenda = CooldownBarrasSL;
      Print("COOLDOWN VENDA: ", CooldownBarrasSL, " barras");
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
