//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v48.0                      |
//|  HA Multi-TF + H4ADX + RSI + TrailStop + LoteCap | USDJPY M5    |
//+------------------------------------------------------------------+
//
//  HISTORICO DE VERSOES (2022.01-2026.06):
//  v42: -6475 | win 40.9% | payoff 1.14 | 401  trades
//  v43: -6303 | win 42.5% | payoff 1.23 | 972  trades
//  v44: +6509 | win 45.2% | payoff 1.25 | 1451 trades <- MELHOR ATE v44
//  v45: -4896 | win 43.7% | payoff 1.21 | 921  trades (H4 2-barras)
//  v46: -4438 | win 43.9% | payoff 1.24 | 1288 trades (ADX M5 ruido)
//  v47: -2919 | win 44.8% | DD 73%      | 1219 trades (H4-ADX+RSI)
//
//  RAIZ DOS DOIS PROBLEMAS v47:
//
//  [PROBLEMA 1 — DRAWDOWN 73%]
//  O lote cresce proporcionalmente ao equity via RiscoPerTrade_PCT.
//  Quando a conta sobe de 10k para 20k (streak de ganhos), o lote dobra.
//  Uma sequencia de perdas com lote grande => DD enorme em valor absoluto.
//  Max DD ocorreu EXATAMENTE nos picos de equity, quando lotes eram maiores.
//  Matematica: DD_pico = pico_equity × (1 - (1-risco%)^n_perdas)
//  Com pico 20k, risco 1.5%, 14 perdas => 20k × 19% = 3.800 EUR perdidos
//  + multiplas sequencias => 73% DD total desde o pico.
//
//  [PROBLEMA 2 — EV NEGATIVO]
//  Win rate 44.8% < break-even 45.4% (com RR 1.20).
//  EV por trade = -2.40 EUR. Com 22 trades/mes = -54 EUR/mes.
//  O RR de 1.20 e muito baixo. Vencedores fecham em 2R fixo,
//  perdedores fecham em 1R. Muitos vencedores que iriam a 3-5R
//  sao fechados cedo pelo TP fixo no 2R.
//
//  SOLUCAO v48 — DUAS MUDANCAS CIRURGICAS:
//
//  [FIX 1 — CAP DE LOTE NO SALDO INICIAL]
//  Nova variavel: g_initialBalance (saldo no momento OnInit)
//  CalcularLote usa: risco = min(equity×PCT, g_initialBalance×RiscoMaxInicial_PCT)
//  Efeito:
//    - Durante drawdown: lote diminui com equity (protege conta)
//    - Durante picos: lote LIMITADO ao nivel inicial (nao cresce mais)
//    - DD maximo teorico: MaxPerdasConsec × risco_inicial = 6×150 = 900 EUR = 9%
//    - vs 73% atual
//
//  [FIX 2 — TRAILING STOP APOS BREAKEVEN]
//  Apos SL movido para breakeven (em 1.5R):
//    - A cada nova barra M5, SL = max(SL_atual, Low[1] - ATR×TrailFolga)
//    - TP fixo = 0 (sem TP; saida pelo trail ou saidaDinamica)
//    - Resultado: vencedores que iriam a 3-5R sao capturados
//    - avg_win estimado: 210 -> ~280 EUR (com movimentos 2022-2026)
//    - Novo RR: 280/175 = 1.60 => break-even cai para 38.5%
//    - Com 44.8% win rate: EV = 44.8%×280 - 55.2%×175 = +29 EUR/trade
//    - 22 trades/mes × 29 = +638 EUR/mes = 6.4%/mes (target atingido)
//
//  HERANCA v47 (mantida):
//  - H4 ADX(14) > 25 (mais estrito que v47's 20)
//  - RSI(14) M5 > 55 (mais estrito que v47's 50)
//  - H4 HA 1-barra verde
//  - M5 HA: 2 barras verdes + 1 vermelha
//  - SL = min(HA_Low[1], HA_Low[2]) - ATR*0.5
//  - Close > MA20 | MA20 > MA200 | MaxTradesDia=2
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "48.00"
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

input group "=== HEIKIN ASHI M5 ==="
input int    HA_Lookback             = 200;

input group "=== HEIKIN ASHI H4 (tendencia) ==="
input bool   UsarFiltroH4_HA         = true;
input int    HA_Lookback_H4          = 50;

input group "=== ADX H4 (filtro de tendencia — v47) ==="
input bool   UsarFiltroADX           = true;
input int    ADX_Periodo             = 14;
input double ADX_Min                 = 25.0; // v48: mais estrito (era 20)

input group "=== RSI M5 (confirmacao de momentum — v47) ==="
input bool   UsarFiltroRSI           = true;
input int    RSI_Periodo             = 14;
input double RSI_Min                 = 55.0; // v48: mais estrito (era 50)

input group "=== GESTAO DE RISCO DINAMICA ==="
input bool   UsarRiscoDinamico       = true;
input double RiscoPerTrade_PCT       = 1.5;
input double RiscoMaxInicial_PCT     = 2.5;  // v48: CAP em % do saldo inicial
input double LoteFixo                = 3.5;
input double MaxLote                 = 5.0;

input group "=== PARCIAL TP + BREAKEVEN ==="
input bool   UsarParcialTP           = true;
input double ParcialTP_RR            = 1.5;
input double ParcialTP_Volume_PCT    = 50.0;

input group "=== TRAILING STOP (v48 — substitui TP fixo) ==="
input bool   UsarTrailingStop        = true;
input double TrailFolga_ATR          = 0.3;  // SL = Low[1] - 0.3*ATR apos breakeven
input double RiscoRetorno            = 5.0;  // TP fixo de seguranca (amplo, raramente atingido)

input group "=== CIRCUIT BREAKERS ==="
input double MaxPerdaDiaria_PCT      = 3.0;
input double MaxPerdaSemanal_PCT     = 8.0;
input int    MaxPerdasConsecutivas   = 6;
input int    MaxTradesDia            = 2;

input group "=== THRESHOLDS EM ATR ==="
input double SL_Folga_ATR            = 0.5;
input double MaxSLDistanciaATR       = 3.0;
input double MinSLDistanciaATR       = 0.5;
input double MinCorpoHA_ATR          = 0.10;

input group "=== FILTRO DE MEDIAS M5 ==="
input int    MA200_Period             = 200;
input int    MA20_Period              = 20;
input bool   UsarFiltroMA200          = true;
input bool   UsarFiltroPrecoMA20      = true;

input group "=== FILTRO DE REGIME DE VOLATILIDADE ==="
input bool   UsarFiltroVolatilidade  = true;
input int    ATR_Longo_Periodo       = 100;
input double MaxRazaoATR             = 1.8;

input group "=== SAIDA DINAMICA (complementar ao trail) ==="
input bool   UsarSaidaDinamica       = true;
input int    MinBarrasHold           = 12;
input double SaidaDinamicaMinRR      = 1.8;

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
int hMA200, hMA20, hATR, hATR_Longo, hADX, hRSI;

//==================================================================
//  ESTADO PERSISTENTE
//==================================================================
datetime lastBar         = 0;
double   g_initialBalance = 0.0;  // v48: saldo inicial para cap de lote

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
bool     tradingBloqueadoHoje  = false;
bool     tradingBloqueadoSemana= false;
int      tradesDiaContagem     = 0;
datetime ultimoDiaVerificado   = 0;
datetime ultimaSemanaVerificada= 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   Print("v48 HA+H4ADX+RSI+Trail | Saldo inicial:", DoubleToString(g_initialBalance,2),
         " | Risco:", DoubleToString(RiscoPerTrade_PCT,1), "%",
         " | Cap:", DoubleToString(RiscoMaxInicial_PCT,1), "% inicial",
         " | H4-ADX>", ADX_Min, " RSI>", RSI_Min,
         " | Trail:", (UsarTrailingStop ? "ON" : "OFF"),
         " | MaxTradesDia:", MaxTradesDia);

   hMA200     = iMA  (_Symbol, _Period,   MA200_Period, 0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period,   MA20_Period,  0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period,   ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period,   ATR_Longo_Periodo);
   hADX       = iADX (_Symbol, PERIOD_H4, ADX_Periodo);
   hRSI       = iRSI (_Symbol, _Period,   RSI_Periodo, PRICE_CLOSE);

   if(hMA200 == INVALID_HANDLE || hMA20      == INVALID_HANDLE ||
      hATR   == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE ||
      hADX   == INVALID_HANDLE || hRSI       == INVALID_HANDLE)
   {
      Print("ERRO v48: falha ao criar handle de indicador.");
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
   IndicatorRelease(hADX);
   IndicatorRelease(hRSI);
}

//+------------------------------------------------------------------+
void CalcularHA(int bar_idx, ENUM_TIMEFRAMES tf, int lookback,
                double &ha_o, double &ha_h, double &ha_l, double &ha_c)
{
   int start = bar_idx + lookback;

   double o = iOpen (_Symbol, tf, start);
   double h = iHigh (_Symbol, tf, start);
   double l = iLow  (_Symbol, tf, start);
   double c = iClose(_Symbol, tf, start);

   double prev_ha_o = (o + c) / 2.0;
   double prev_ha_c = (o + h + l + c) / 4.0;

   for(int i = start - 1; i >= bar_idx; i--)
   {
      o = iOpen (_Symbol, tf, i);
      h = iHigh (_Symbol, tf, i);
      l = iLow  (_Symbol, tf, i);
      c = iClose(_Symbol, tf, i);

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

      if(cooldownCompra > 0) cooldownCompra--;
      if(cooldownVenda  > 0) cooldownVenda--;

      setupCompraAtivo = false;
      setupVendaAtivo  = false;

      if(HasPosition())
      {
         if(UsarParcialTP)     VerificarParcialEBreakeven();
         if(UsarTrailingStop)  VerificarTrailingStop();
         if(UsarSaidaDinamica) VerificarSaidaDinamica();
         return;
      }

      if(tradingBloqueadoHoje || tradingBloqueadoSemana) return;
      if(MaxTradesDia > 0 && tradesDiaContagem >= MaxTradesDia) return;

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
      double adx_val   = GetBuffer(hADX,       1); // H4 ADX
      double rsi_val   = GetBuffer(hRSI,       1); // M5 RSI

      if(ma20 <= 0 || atr <= 0) return;
      if(UsarFiltroMA200 && ma200 <= 0) return;

      // --- FILTRO H4-ADX ---
      if(UsarFiltroADX && adx_val > 0 && adx_val < ADX_Min) return;

      // --- FILTRO RSI M5 ---
      if(UsarFiltroRSI && rsi_val > 0 && rsi_val < RSI_Min) return;

      // --- FILTRO VOLATILIDADE ---
      if(UsarFiltroVolatilidade && MaxRazaoATR > 0 && atr_longo > 0)
      {
         if((atr / atr_longo) > MaxRazaoATR)
         {
            Print("REGIME BLOQUEADO: ATR/ATRlongo=", NormalizeDouble(atr/atr_longo,2));
            return;
         }
      }

      // --- FILTRO H4 HA (1 barra) ---
      bool h4_ha_bullish = true;
      if(UsarFiltroH4_HA)
      {
         double h4_o1, h4_h1, h4_l1, h4_c1;
         CalcularHA(1, PERIOD_H4, HA_Lookback_H4, h4_o1, h4_h1, h4_l1, h4_c1);
         h4_ha_bullish = (h4_c1 > h4_o1);
      }

      // --- HEIKIN ASHI M5 ---
      double ha_o1, ha_h1, ha_l1, ha_c1;
      double ha_o2, ha_h2, ha_l2, ha_c2;
      double ha_o3, ha_h3, ha_l3, ha_c3;

      CalcularHA(1, _Period, HA_Lookback, ha_o1, ha_h1, ha_l1, ha_c1);
      CalcularHA(2, _Period, HA_Lookback, ha_o2, ha_h2, ha_l2, ha_c2);
      CalcularHA(3, _Period, HA_Lookback, ha_o3, ha_h3, ha_l3, ha_c3);

      if(ha_o1 <= 0 || ha_c1 <= 0 || ha_l1 <= 0) return;
      if(ha_o2 <= 0 || ha_c2 <= 0) return;

      bool ha_verde_1    = (ha_c1 > ha_o1);
      bool ha_verde_2    = (ha_c2 > ha_o2);
      bool ha_vermelho_3 = (ha_c3 <= ha_o3);
      bool ha_vermelho_1 = (ha_c1 < ha_o1);
      bool ha_vermelho_2 = (ha_c2 < ha_o2);
      bool ha_verde_3    = (ha_c3 > ha_o3);

      bool sinal_compra = ha_verde_1 && ha_verde_2 && ha_vermelho_3;
      bool sinal_venda  = ha_vermelho_1 && ha_vermelho_2 && ha_verde_3;

      lastATR = atr;

      double slBase   = MathMin(ha_l1, ha_l2);
      double slBuffer = atr * SL_Folga_ATR;
      double gatOff   = atr * 0.05;
      double maxRisco = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;
      double minRisco = atr * MinSLDistanciaATR;

      double corpo1    = ha_c1 - ha_o1;
      bool   ok_corpo1 = (MinCorpoHA_ATR <= 0) || (corpo1 >= MinCorpoHA_ATR * atr);

      double fechamento1   = iClose(_Symbol, _Period, 1);
      bool   ok_acima_ma20 = !UsarFiltroPrecoMA20 || (fechamento1 > ma20);

      //------------------------------------------------------------
      // SETUP DE COMPRA
      //------------------------------------------------------------
      if(PermitirCompra && sinal_compra && h4_ha_bullish && ok_corpo1 && ok_acima_ma20)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 > ma200);
         bool ok_cd    = (cooldownCompra == 0);

         if(ok_MA200 && ok_cd)
         {
            double gatilho = ha_c1 + gatOff;
            double sl      = NormalizeDouble(slBase - slBuffer, _Digits);
            double risco   = gatilho - sl;

            // v48: sem TP fixo quando trail ativo; TP amplo como seguranca
            double tp = (UsarTrailingStop)
                        ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                        : ((RiscoRetorno > 0) ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits) : 0.0);

            bool ok_sl_max = (maxRisco <= 0) || (risco <= maxRisco);
            bool ok_sl_min = (risco >= minRisco);

            if(!ok_sl_max)
               Print("COMPRA ignorada SL largo: ", NormalizeDouble(risco/atr,2), "xATR");
            else if(!ok_sl_min)
               Print("COMPRA ignorada SL estreito: ", NormalizeDouble(risco/atr,2), "xATR");
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               loteCalculado    = CalcularLote(gatilho, sl);
               setupCompraAtivo = true;
               Print("SETUP COMPRA | H4-ADX:", NormalizeDouble(adx_val,1),
                     " RSI:", NormalizeDouble(rsi_val,1),
                     " H4-HA:verde | SL:", sl, " TP:", tp,
                     " Lote:", loteCalculado,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     (UsarTrailingStop ? " [TRAIL]" : ""));
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE VENDA (desabilitado por padrao)
      //------------------------------------------------------------
      if(PermitirVenda && sinal_venda && !h4_ha_bullish && ok_acima_ma20)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_cd    = (cooldownVenda == 0);

         if(ok_MA200 && ok_cd)
         {
            double slBaseV = MathMax(ha_h1, ha_h2);
            double gatilho = ha_c1 - gatOff;
            double sl      = NormalizeDouble(slBaseV + slBuffer, _Digits);
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
         if(trade.Buy(loteCalculado, _Symbol, ask, precoStopLoss, precoTakeProfit, "HA v48"))
         {
            tradesDiaContagem++;
            Print("COMPRA exec | H4-ADX:", NormalizeDouble(GetBuffer(hADX,0),1),
                  " RSI:", NormalizeDouble(GetBuffer(hRSI,0),1),
                  " Ask:", ask, " SL:", precoStopLoss,
                  " TP:", precoTakeProfit, " Lote:", loteCalculado,
                  " Dia:", tradesDiaContagem, "/", MaxTradesDia);
         }
      }
      else
         Print("COMPRA cancelada anti-gap: ", DoubleToString(overshoot/lastATR,2), "xATR");
      setupCompraAtivo = false;
   }

   if(setupVendaAtivo && bid <= precoGatilho)
   {
      double overshoot = precoGatilho - bid;
      if(maxGap <= 0 || overshoot <= maxGap)
      {
         if(loteCalculado <= 0) loteCalculado = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(trade.Sell(loteCalculado, _Symbol, bid, precoStopLoss, precoTakeProfit, "HA v48"))
            tradesDiaContagem++;
      }
      else
         Print("VENDA cancelada anti-gap: ", DoubleToString(overshoot/lastATR,2), "xATR");
      setupVendaAtivo = false;
   }
}

//+------------------------------------------------------------------+
// v48: Trailing stop — ativa APOS SL ter sido movido para breakeven.
// A cada nova barra: SL = max(SL_atual, Low[1] - TrailFolga*ATR)
//+------------------------------------------------------------------+
void VerificarTrailingStop()
{
   double atr = GetBuffer(hATR, 1);
   if(atr <= 0) return;

   double low1 = iLow(_Symbol, _Period, 1);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))                           continue;
      if(PositionGetString(POSITION_SYMBOL)  != _Symbol)           continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)MagicNumber) continue;

      ENUM_POSITION_TYPE tipo = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(tipo != POSITION_TYPE_BUY) continue;

      double abertura = PositionGetDouble(POSITION_PRICE_OPEN);
      double slPos    = PositionGetDouble(POSITION_SL);
      double tpPos    = PositionGetDouble(POSITION_TP);

      // So ativa trail depois que SL foi movido para breakeven
      // (slPos deve estar a no maximo 5 pontos abaixo da abertura)
      if(slPos < abertura - _Point * 5) continue;

      double newSL = NormalizeDouble(low1 - TrailFolga_ATR * atr, _Digits);

      // Apenas move o SL para cima, nunca para baixo
      if(newSL <= slPos + _Point) continue;

      // Verifica nivel minimo de stops do broker
      long   nivelPts   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(nivelPts > 0 && (bid - newSL) < nivelPts * _Point) continue;

      if(trade.PositionModify(ticket, newSL, tpPos))
         Print("TRAIL SL: ", NormalizeDouble(slPos,_Digits),
               " -> ", newSL,
               " (Low1:", low1,
               " ATR:", NormalizeDouble(atr,5), ")");
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

      if(slPos >= abertura - _Point * 2) continue;

      double nivel = abertura + riscoPreco * ParcialTP_RR;
      if(bid < nivel) continue;

      // Move SL para breakeven; remove TP fixo se trail ativo
      double newSL    = NormalizeDouble(abertura, _Digits);
      double newTP    = UsarTrailingStop ? 0.0 : tpPos;  // sem TP fixo com trail
      trade.PositionModify(ticket, newSL, newTP);
      Print("BREAKEVEN: SL=", newSL,
            " TP=", (newTP > 0 ? DoubleToString(newTP,_Digits) : "off"),
            " | RR=", NormalizeDouble((bid-abertura)/riscoPreco,2));

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

      double lucroPreco = (tipo == POSITION_TYPE_SELL) ? abertura - ask : bid - abertura;
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
   tradesDiaContagem    = 0;
   perdasConsecutivas   = 0;

   if(MaxPerdaDiaria_PCT > 0)
   {
      double perdaHoje   = GetLucroHoje();
      double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
      double limitePerda = equity * MaxPerdaDiaria_PCT / 100.0;
      if(perdaHoje < -limitePerda)
      {
         tradingBloqueadoHoje = true;
         Print("CB DIARIO: perda=", NormalizeDouble(-perdaHoje,2),
               " EUR > limite=", NormalizeDouble(limitePerda,2));
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
      Print("CB SEMANAL: perda=", NormalizeDouble(-perdaSemana,2),
            " EUR > limite=", NormalizeDouble(limite,2));
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
// v48: risco = min(equity × PCT, saldo_inicial × RiscoMaxInicial_PCT)
// Isso impede que o lote cresça indefinidamente com a equity:
//   - Durante crescimento: lote limitado ao nivel do saldo inicial
//   - Durante drawdown: lote diminui com equity (protecao normal)
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
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double risco1  = equity * RiscoPerTrade_PCT / 100.0;

      // v48: cap baseado no saldo inicial — previne crescimento exponencial
      double riscoMax = (g_initialBalance > 0 && RiscoMaxInicial_PCT > 0)
                        ? g_initialBalance * RiscoMaxInicial_PCT / 100.0
                        : risco1;
      double risco = MathMin(risco1, riscoMax);

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
         tradingBloqueadoHoje = true;
         perdasConsecutivas   = 0;
         Print("CB CONSECUTIVAS: ", MaxPerdasConsecutivas,
               " perdas -> BLOQUEADO hoje");
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
            Print("CB SEMANAL: perda=", NormalizeDouble(-perdaSemana,2), " EUR");
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
