//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v42.0                      |
//|  Heikin Ashi Nativo | BUY-only | Risco Dinamico | USDJPY M5      |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v41 (300 trades, 2025.01-2026.06):
//  - Lucro liquido: -1.681 EUR (PREJUIZO)
//  - Max DD: 39.83% — igual ao v31 apesar do risco dinamico
//  - PF: 0.91 | Payoff ratio: 0.93 (avg win 110 < avg loss 118)
//
//  POR QUE v41 FALHOU:
//  [A] SELL: 29.63% win => EV -50 EUR/trade => -4.050 EUR no total
//  [B] Parcial TP em 1xRR: avg win (110) < avg loss (118) => EV negativo
//  [C] Circuit breaker diario: 3%/dia × 10 dias ruins = 30% DD acumulado
//
//  SOLUCAO v42 — HEIKIN ASHI NATIVO (equivalente ao Crystal Heikin Ashi):
//
//  O indicador Crystal Heikin Ashi nao pode ser carregado via iCustom
//  no Strategy Tester pois indicadores Market ficam em pasta protegida.
//  Solucao: calcular HA diretamente no EA com as formulas exatas:
//    HA_Close = (O + H + L + C) / 4
//    HA_Open  = (HA_Open[prev] + HA_Close[prev]) / 2
//    HA_High  = max(H, HA_Open, HA_Close)
//    HA_Low   = min(L, HA_Open, HA_Close)
//  Convergencia: com lookback >= 100 barras, HA_Open converge para o
//  mesmo valor que qualquer implementacao padrao.
//  O sinal de entrada e identico ao Crystal Heikin Ashi visual.
//
//  SINAL BUY: barra [1] e verde (HA_Close > HA_Open)
//             barra [2] era vermelha (HA_Close <= HA_Open)
//  SL: abaixo de HA_Low[1] — nivel suavizado, mais robusto que L1 real
//
//  OUTRAS MELHORIAS vs v41:
//  [1] SELL desabilitado (PermitirVenda=false)
//  [2] ParcialTP_RR = 1.5 (era 1.0) => avg win > avg loss => EV positivo
//  [3] Circuit breaker semanal (8%) além do diario (3%)
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "42.00"
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
input bool   PermitirVenda           = false;  // SELL: 29.63% win v41 — desabilitado

input group "=== HEIKIN ASHI ==="
input int    HA_Lookback             = 200;    // Barras para convergencia do HA_Open
                                               // >= 100 garante precisao identica ao Crystal HA

input group "=== GESTAO DE RISCO DINAMICA ==="
input bool   UsarRiscoDinamico       = true;
input double RiscoPerTrade_PCT       = 1.5;    // % do equity por trade
input double LoteFixo                = 3.5;    // Lote fixo (UsarRiscoDinamico=false)
input double MaxLote                 = 5.0;    // Teto absoluto de lote
input double RiscoRetorno            = 2.0;

input group "=== PARCIAL TP + BREAKEVEN ==="
input bool   UsarParcialTP           = true;
input double ParcialTP_RR            = 1.5;    // v42: 1.5 (era 1.0) — melhora payoff
input double ParcialTP_Volume_PCT    = 50.0;

input group "=== CIRCUIT BREAKERS ==="
input double MaxPerdaDiaria_PCT      = 3.0;
input double MaxPerdaSemanal_PCT     = 8.0;    // Novo: para na semana se DD > 8%
input int    MaxPerdasConsecutivas   = 5;
input int    CooldownPerdasConsec    = 30;

input group "=== THRESHOLDS EM ATR ==="
input double SL_Folga_ATR            = 0.15;   // Folga abaixo do HA_Low para o SL
input double MaxSLDistanciaATR       = 3.0;    // Ignora sinal se SL > 3xATR
input double MinSLDistanciaATR       = 0.3;    // Ignora sinal se SL < 0.3xATR (lote enorme)

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
datetime ultimoDiaVerificado   = 0;
datetime ultimaSemanaVerificada= 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   Print("v42 HA Nativo | Risco:",
         (UsarRiscoDinamico ? DoubleToString(RiscoPerTrade_PCT,1)+"%" : "fixo "+DoubleToString(LoteFixo,2)),
         " | MaxLote:", MaxLote,
         " | ParcialTP RR:", ParcialTP_RR,
         " | CBdiario:", MaxPerdaDiaria_PCT, "%",
         " | CBsemanal:", MaxPerdaSemanal_PCT, "%",
         " | HA_Lookback:", HA_Lookback,
         " | FiltroH4:", (UsarFiltroTendenciaH4 ? "ON" : "OFF"),
         " | FiltroVol:", (UsarFiltroVolatilidade ? "ON" : "OFF"));

   hMA200     = iMA  (_Symbol, _Period,   MA200_Period,    0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period,   MA20_Period,     0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period,   ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period,   ATR_Longo_Periodo);
   hMA_H4     = iMA  (_Symbol, PERIOD_H4, MA_H4_Period,   0, MODE_SMA, PRICE_CLOSE);

   if(hMA200 == INVALID_HANDLE || hMA20      == INVALID_HANDLE ||
      hATR   == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE ||
      hMA_H4 == INVALID_HANDLE)
   {
      Print("ERRO v42: falha ao criar handle de indicador.");
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
// Calcula Heikin Ashi para a barra bar_idx usando lookback barras de
// aquecimento para convergencia do HA_Open.
// Formulas identicas ao Crystal Heikin Ashi (variante padrao).
//+------------------------------------------------------------------+
void CalcularHA(int bar_idx,
                double &ha_o, double &ha_h, double &ha_l, double &ha_c)
{
   int start = bar_idx + HA_Lookback;

   // inicializar com a barra mais antiga do lookback
   double o = iOpen (_Symbol, _Period, start);
   double h = iHigh (_Symbol, _Period, start);
   double l = iLow  (_Symbol, _Period, start);
   double c = iClose(_Symbol, _Period, start);

   double prev_ha_o = (o + c) / 2.0;
   double prev_ha_c = (o + h + l + c) / 4.0;

   // iterar do mais antigo ate a barra alvo
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

      // --- HEIKIN ASHI NATIVO ---
      double ha_o1, ha_h1, ha_l1, ha_c1; // barra fechada [1]
      double ha_o2, ha_h2, ha_l2, ha_c2; // barra anterior [2]

      CalcularHA(1, ha_o1, ha_h1, ha_l1, ha_c1);
      CalcularHA(2, ha_o2, ha_h2, ha_l2, ha_c2);

      if(ha_o1 <= 0 || ha_c1 <= 0 || ha_l1 <= 0) return;

      bool ha_verde_1    = (ha_c1 > ha_o1);   // barra [1]: bullish (verde)
      bool ha_vermelho_1 = (ha_c1 < ha_o1);   // barra [1]: bearish (vermelho)
      bool ha_verde_2    = (ha_c2 > ha_o2);   // barra [2]: bullish
      bool ha_vermelho_2 = (ha_c2 < ha_o2);   // barra [2]: bearish

      // Flip: HA virou VERDE (sinal BUY) — anterior era nao-verde
      bool sinal_compra = ha_verde_1 && !ha_verde_2;
      // Flip: HA virou VERMELHO (sinal SELL) — anterior era nao-vermelho
      bool sinal_venda  = ha_vermelho_1 && !ha_vermelho_2;

      lastATR = atr;

      double slBuffer = atr * SL_Folga_ATR;
      double gatOff   = atr * 0.05;
      double maxRisco = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;
      double minRisco = atr * MinSLDistanciaATR;

      //------------------------------------------------------------
      // SETUP DE COMPRA — HA vira verde
      //------------------------------------------------------------
      if(PermitirCompra && sinal_compra && tendencia_alta_h4)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 > ma200);
         bool ok_cd    = (cooldownCompra == 0);

         if(ok_MA200 && ok_cd)
         {
            double gatilho = ha_c1 + gatOff;
            double sl      = NormalizeDouble(ha_l1 - slBuffer, _Digits);
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
               Print("SETUP COMPRA (HA verde) | SL:", sl, " TP:", tp,
                     " Lote:", loteCalculado,
                     " HA_Low:", NormalizeDouble(ha_l1, _Digits),
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     " MA20:", NormalizeDouble(ma20,3), ">MA200:", NormalizeDouble(ma200,3));
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE VENDA — HA vira vermelho (desabilitado por padrao)
      //------------------------------------------------------------
      if(PermitirVenda && sinal_venda && !tendencia_alta_h4)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_cd    = (cooldownVenda == 0);

         if(ok_MA200 && ok_cd)
         {
            double gatilho = ha_c1 - gatOff;
            double sl      = NormalizeDouble(ha_h1 + slBuffer, _Digits);
            double risco   = sl - gatilho;
            double tp      = (RiscoRetorno > 0)
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
               Print("SETUP VENDA (HA vermelho) | SL:", sl, " TP:", tp,
                     " Lote:", loteCalculado, " risco:", NormalizeDouble(risco/atr,2), "xATR");
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
         trade.Buy(loteCalculado, _Symbol, ask, precoStopLoss, precoTakeProfit, "HA v42");
         Print("COMPRA executada | Ask:", ask, " SL:", precoStopLoss,
               " TP:", precoTakeProfit, " Lote:", loteCalculado);
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
         trade.Sell(loteCalculado, _Symbol, bid, precoStopLoss, precoTakeProfit, "HA v42");
         Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss,
               " TP:", precoTakeProfit, " Lote:", loteCalculado);
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

      // mover SL para breakeven primeiro
      double newSL = NormalizeDouble(abertura, _Digits);
      trade.PositionModify(ticket, newSL, tpPos);
      Print("BREAKEVEN: SL=", newSL, " | RR=", NormalizeDouble((bid-abertura)/riscoPreco,2));

      // fechar parcial
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
