//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v41.0                      |
//|  Gestao de Risco Dinamica | Parcial TP | Circuit Breakers        |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v31 (287 BUY, 2025.01-2026.06 — base desta analise):
//  - Win rate 38.33% | PF 1.23 | Lucro +8.115 EUR = +4.77%/mes
//  - PROBLEMA CRITICO: Max DD 40.11% (4.681 EUR em conta de 10K)
//  - Maior perda isolada: -1.321 EUR = 13.2% da conta (1 trade!)
//  - Maior sequencia de losses: 8 trades = -2.862 EUR = 28.6% DD
//
//  CAUSAS DO DD EXCESSIVO:
//  [A] Lote fixo ignora distancia do SL: quando ATR expande (mercado
//      volatil), o SL fica mais largo, mas o lote nao reduz => trade
//      individual pode valer 13% da conta.
//  [B] Sem protecao diaria: apos 3-4 losses num dia ruim, o robo
//      continua operando, acumulando DD rapidamente.
//  [C] Winners que viram losers: sem mecanismo de breakeven, trades
//      que chegam a 1.5xRR e retoram ao SL destroem lucros acumulados.
//
//  SOLUCOES v41 (3 camadas de defesa):
//
//  [1] RISCO DINAMICO (mais impactante):
//      Calcula o lote para que cada trade arrisque exatamente 1% do
//      equity, independente da distancia do SL.
//      - Conta 10K: ~100 EUR por trade (vs 203 EUR fixo no v31)
//      - SL largo (ATR alto): lote reduz automaticamente
//      - SL curto (ATR normal): lote aumenta ate MaxLote
//      - 8 losses consecutivos maximos => ~8% DD (vs 28% no v31)
//      - Maior perda isolada estimada: ~100 EUR (vs -1.321 no v31!)
//
//  [2] PARCIAL TP + BREAKEVEN:
//      Ao preco atingir 1xRR de lucro: fecha 50% da posicao e move
//      SL para o preco de entrada.
//      - Elimina "winner que virou loser" (posicao restante risco=0)
//      - Garante lucro minimo em trades que chegam a 1:1
//      - Suaviza curva de equity: menos picos e vales bruscos
//
//  [3] CIRCUIT BREAKERS:
//      A) Perda diaria: para de operar no dia se perda acumulada
//         ultrapassar 3% do equity. Evita days ruins em espiral.
//      B) Losses consecutivos: apos 5 losses seguidos, aguarda 30
//         barras antes de retomar. Evita entrar em sequencias ruins.
//
//  PROJECAO v41 vs v31:
//  - Max DD estimado: ~8-12% (vs 40% no v31)
//  - Lucro estimado com 1% risco: 8.115 * (100/203) = ~4.000 EUR/17m
//    = 235 EUR/mes = 2.35%/mes em 10K
//  - Para manter ~4.5%/mes: usar RiscoPerTrade_PCT=2.0
//    => Max DD estimado: ~16-20% (ainda muito melhor que 40%)
//  - Recomendacao: comecar com 1.5% (meta ~3.5%/mes, DD<15%)
//
//  BASE: v38 (filtro H4 + MA50 Daily + regime volatilidade + BuySell)
//  NOVIDADES v41: risco dinamico + parcial BE + circuit breakers
//
//+------------------------------------------------------------------+
#property copyright "Seu Nome"
#property version   "41.00"
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

input group "=== GESTAO DE RISCO DINAMICA ==="
input bool   UsarRiscoDinamico       = true;    // true=% equity | false=lote fixo
input double RiscoPerTrade_PCT       = 1.5;     // % do equity arriscado por trade
                                                 // 1.0%: DD<12%, meta ~2.4%/mes
                                                 // 1.5%: DD<18%, meta ~3.5%/mes
                                                 // 2.0%: DD<22%, meta ~4.6%/mes
input double LoteFixo                = 3.5;     // Lote fixo (UsarRiscoDinamico=false)
input double MaxLote                 = 5.0;     // Teto absoluto de lote
input double RiscoRetorno            = 2.0;

input group "=== PARCIAL TP + BREAKEVEN ==="
input bool   UsarParcialTP           = true;    // Fechar parcial ao atingir 1xRR
input double ParcialTP_RR            = 1.0;     // RR para acionar parcial
input double ParcialTP_Volume_PCT    = 50.0;    // % do volume a fechar no parcial

input group "=== CIRCUIT BREAKERS ==="
input double MaxPerdaDiaria_PCT      = 3.0;     // Para no dia se perda > X% equity (0=off)
input int    MaxPerdasConsecutivas   = 5;       // Pausa apos N losses seguidos (0=off)
input int    CooldownPerdasConsec    = 30;      // Barras de pausa apos N losses consec

input group "=== THRESHOLDS EM ATR ==="
input double MinAfastamentoATR       = 1.7;
input double PavioMinimoATR          = 0.25;
input double SL_Folga_ATR            = 0.2;
input double MaxSLDistanciaATR       = 2.5;     // Teto de SL em ATR (0=desabilitado)

input group "=== FILTRO DIARIO PARA VENDA ==="
input bool   UsarFiltroMaDiaria      = true;
input int    MA_Diaria_Period         = 50;

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
input int    MinBarrasHold           = 15;
input double SaidaDinamicaMinRR      = 2.0;

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
input int    CooldownBarrasSL        = 5;       // v41: elevado de 3 para 5

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
double gSL_Folga_ATR;

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

// v41: circuit breakers
int      perdasConsecutivas   = 0;
int      cooldownConsecutivo  = 0;
bool     tradingBloqueadoHoje = false;
datetime ultimoDiaVerificado  = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   gMinAfastamentoATR = MathMax(MinAfastamentoATR, 1.5);
   gSL_Folga_ATR      = MathMax(SL_Folga_ATR,      0.1);

   if(gMinAfastamentoATR != MinAfastamentoATR)
      Print("AVISO v41: MinAfastamentoATR elevado ao floor de ", gMinAfastamentoATR);
   if(gSL_Folga_ATR != SL_Folga_ATR)
      Print("AVISO v41: SL_Folga_ATR elevado ao floor de ", gSL_Folga_ATR);

   Print("v41 | Risco:", (UsarRiscoDinamico
            ? DoubleToString(RiscoPerTrade_PCT,1) + "%/trade din"
            : "fixo " + DoubleToString(LoteFixo,2) + " lotes"),
         " | MaxLote:", MaxLote,
         " | ParcialTP:", (UsarParcialTP ? "ON" : "OFF"),
         " | DD-diario:", MaxPerdaDiaria_PCT, "%",
         " | LossConsec:", MaxPerdasConsecutivas,
         " | FiltroH4:", (UsarFiltroTendenciaH4 ? "ON" : "OFF"),
         " | FiltroD1:", (UsarFiltroMaDiaria ? "ON" : "OFF"),
         " | FiltroVol:", (UsarFiltroVolatilidade ? "ON" : "OFF"));

   hMA200     = iMA  (_Symbol, _Period,   MA200_Period,     0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period,   MA20_Period,      0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period,   ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period,   ATR_Longo_Periodo);
   hMA_H4     = iMA  (_Symbol, PERIOD_H4, MA_H4_Period,    0, MODE_SMA, PRICE_CLOSE);
   hMA_D1     = iMA  (_Symbol, PERIOD_D1, MA_Diaria_Period, 0, MODE_SMA, PRICE_CLOSE);

   if(hMA200  == INVALID_HANDLE || hMA20      == INVALID_HANDLE ||
      hATR    == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE ||
      hMA_H4  == INVALID_HANDLE || hMA_D1     == INVALID_HANDLE)
   {
      Print("ERRO v41: falha ao criar handle de indicador.");
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

      VerificarResetDiario(barAtual);

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

      if(tradingBloqueadoHoje || cooldownConsecutivo > 0) return;

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

      if(UsarFiltroVolatilidade && MaxRazaoATR > 0 && atr_longo > 0)
      {
         double razao = atr / atr_longo;
         if(razao > MaxRazaoATR)
         {
            Print("REGIME BLOQUEADO: ATR(", ATR_Periodo, ")/ATR(", ATR_Longo_Periodo,
                  ") = ", NormalizeDouble(razao,2), " > ", MaxRazaoATR);
            return;
         }
      }

      double ma_h4_now = GetBuffer(hMA_H4, 1);
      double ma_h4_old = GetBuffer(hMA_H4, 1 + SlopeH4_Barras);

      bool tendencia_alta_h4  = !UsarFiltroTendenciaH4 ||
                                 (ma_h4_now <= 0) || (ma_h4_old <= 0) ||
                                 (ma_h4_now >= ma_h4_old);

      bool tendencia_baixa_h4 = !UsarFiltroTendenciaH4 ||
                                 (ma_h4_now <= 0) || (ma_h4_old <= 0) ||
                                 (ma_h4_now <= ma_h4_old);

      double ma_d1 = GetBuffer(hMA_D1, 1);

      double C1 = iClose(_Symbol, _Period, 1);
      double H1 = iHigh (_Symbol, _Period, 1);
      double L1 = iLow  (_Symbol, _Period, 1);
      double O1 = iOpen (_Symbol, _Period, 1);
      double H2 = iHigh (_Symbol, _Period, 2);
      double L2 = iLow  (_Symbol, _Period, 2);

      double distMA20 = MathAbs(C1 - ma20);
      double distMin  = atr * gMinAfastamentoATR;
      double pavioMin = atr * PavioMinimoATR;
      double slBuffer = atr * gSL_Folga_ATR;
      double gatOff   = atr * 0.08;
      double maxRisco = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;

      lastATR = atr;

      bool sell_cond = (H1 > H2 && C1 <= H2);
      bool buy_cond  = (L1 < L2 && C1 >= L2);

      bool ok_padrao_venda  = sell_cond && (!buy_cond  || C1 < O1);
      bool ok_padrao_compra = buy_cond  && (!sell_cond || C1 > O1);

      //------------------------------------------------------------
      // SETUP DE VENDA - Falha de Topo
      //------------------------------------------------------------
      bool ok_diaria_venda = !UsarFiltroMaDiaria || (ma_d1 <= 0) || (C1 < ma_d1);
      if(PermitirVenda && C1 < ma20 && distMA20 >= distMin && tendencia_baixa_h4 && ok_diaria_venda)
      {
         double pavioSup = H1 - MathMax(O1, C1);

         bool ok_MA200 = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_pavio = (pavioSup >= pavioMin);
         bool ok_cd    = (cooldownVenda == 0);

         if(ok_MA200 && ok_pavio && ok_padrao_venda && ok_cd)
         {
            double gatilho = L1 - gatOff;
            double sl      = NormalizeDouble(H1 + slBuffer, _Digits);
            double risco   = sl - gatilho;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho - risco * RiscoRetorno, _Digits)
                             : 0.0;

            bool ok_sl_dist = (maxRisco <= 0) || (risco <= maxRisco);

            if(!ok_sl_dist)
               Print("VENDA ignorada (SL teto): ", NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_SELL))
            {
               precoGatilho    = gatilho;
               precoStopLoss   = sl;
               precoTakeProfit = tp;
               loteCalculado   = CalcularLote(gatilho, sl);
               setupVendaAtivo = true;
               Print("SETUP VENDA | SL:", sl, " TP:", tp,
                     " Lote:", loteCalculado,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR");
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE COMPRA - Falha de Fundo
      //------------------------------------------------------------
      if(PermitirCompra && C1 < ma20 && distMA20 >= distMin && tendencia_alta_h4)
      {
         double pavioInf = MathMin(O1, C1) - L1;

         bool ok_MA200 = !UsarFiltroMA200 || (ma20 > ma200);
         bool ok_pavio = (pavioInf >= pavioMin);
         bool ok_cd    = (cooldownCompra == 0);

         if(ok_MA200 && ok_pavio && ok_padrao_compra && ok_cd)
         {
            double gatilho = H1 + gatOff;
            double sl      = NormalizeDouble(L1 - slBuffer, _Digits);
            double risco   = gatilho - sl;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                             : 0.0;

            bool ok_sl_dist = (maxRisco <= 0) || (risco <= maxRisco);

            if(!ok_sl_dist)
               Print("COMPRA ignorada (SL teto): ", NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               loteCalculado    = CalcularLote(gatilho, sl);
               setupCompraAtivo = true;
               Print("SETUP COMPRA | SL:", sl, " TP:", tp,
                     " Lote:", loteCalculado,
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     " MA50H4:", NormalizeDouble(ma_h4_now,3));
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
         trade.Buy(loteCalculado, _Symbol, ask, precoStopLoss, precoTakeProfit, "Falha de Fundo v41");
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
         trade.Sell(loteCalculado, _Symbol, bid, precoStopLoss, precoTakeProfit, "Falha de Topo v41");
         Print("VENDA executada | Bid:", bid, " SL:", precoStopLoss,
               " TP:", precoTakeProfit, " Lote:", loteCalculado);
      }
      else
         Print("VENDA cancelada (anti-gap): ", DoubleToString(overshoot/lastATR,2), "xATR");
      setupVendaAtivo = false;
   }
}

//+------------------------------------------------------------------+
// v41: Parcial TP + mover SL para breakeven ao atingir ParcialTP_RR
//
// Logica: quando bid >= entrada + risco * ParcialTP_RR
//   1. Fecha ParcialTP_Volume_PCT% do volume (garante lucro parcial)
//   2. Move SL para preco de entrada (posicao restante: risco zero)
// Deteccao de repetir: slPos >= entrada (BE ja foi movido)
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

      // ja foi processado se SL esta na entrada ou acima
      if(slPos >= abertura - _Point * 2) continue;

      double nivel = abertura + riscoPreco * ParcialTP_RR;
      if(bid < nivel) continue;

      // mover SL para breakeven primeiro
      double newSL = NormalizeDouble(abertura, _Digits);
      trade.PositionModify(ticket, newSL, tpPos);
      Print("BREAKEVEN COMPRA: SL=", newSL, " | preco=", abertura,
            " | RR atingido=", NormalizeDouble((bid-abertura)/riscoPreco,2));

      // fechar parcial
      double volume  = PositionGetDouble(POSITION_VOLUME);
      double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double volParcial = NormalizeDouble(volume * ParcialTP_Volume_PCT / 100.0, 2);
      volParcial = MathFloor(volParcial / volStep) * volStep;
      if(volParcial < volMin) volParcial = volMin;
      if(volParcial >= volume) continue;

      if(trade.PositionClosePartial(ticket, volParcial))
         Print("PARCIAL COMPRA: fechou ", volParcial, " lotes | restante:",
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
// v41: reset bloqueio diario na primeira barra de um novo dia
//+------------------------------------------------------------------+
void VerificarResetDiario(datetime barAtual)
{
   MqlDateTime dt, dtUlt;
   TimeToStruct(barAtual,            dt);
   TimeToStruct(ultimoDiaVerificado, dtUlt);

   bool novoDia = (ultimoDiaVerificado == 0 || dt.day != dtUlt.day ||
                   dt.mon != dtUlt.mon || dt.year != dtUlt.year);
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
         Print("CIRCUIT BREAKER dia: perda=", NormalizeDouble(-perdaHoje,2),
               " EUR (", NormalizeDouble(-perdaHoje/equity*100,2), "%) > limite=",
               NormalizeDouble(limitePerda,2), " EUR");
      }
   }
}

//+------------------------------------------------------------------+
// v41: lucro liquido de deals fechados no dia corrente (magic do EA)
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
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(tk, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         total += HistoryDealGetDouble(tk, DEAL_PROFIT);
   }
   return total;
}

//+------------------------------------------------------------------+
// v41: calcula lote dinamicamente para arriscar RiscoPerTrade_PCT%
//      do equity actual com base na distancia real do SL
//
// Formula: lote = (equity * risco%) / (sl_em_pontos * valor_por_ponto)
// Funciona para qualquer simbolo e moeda da conta (MT5 fornece tickValue)
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

      double slPts = MathAbs(gatilho - sl) / _Point;

      if(slPts <= 0 || ptVal <= 0)
      {
         Print("AVISO CalcularLote: slPts=", slPts, " ptVal=", ptVal, " -> usando LoteFixo");
         lote = LoteFixo;
      }
      else
      {
         lote = risco / (slPts * ptVal);
         Print("Lote calculado: equity=", NormalizeDouble(equity,2),
               " risco=", NormalizeDouble(risco,2),
               " slPts=", NormalizeDouble(slPts,1),
               " ptVal=", NormalizeDouble(ptVal,5),
               " lote=", NormalizeDouble(lote,2));
      }
   }

   lote = MathMax(lotMin, MathMin(MaxLote, MathFloor(lote / lotStep) * lotStep));
   return lote;
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

   // v41: rastrear perdas consecutivas
   if(profit < 0.0)
   {
      perdasConsecutivas++;

      if(MaxPerdasConsecutivas > 0 && perdasConsecutivas >= MaxPerdasConsecutivas)
      {
         cooldownConsecutivo = CooldownPerdasConsec;
         perdasConsecutivas  = 0;
         Print("PAUSA CONSECUTIVA: ", MaxPerdasConsecutivas, " perdas -> cooldown ",
               CooldownPerdasConsec, " barras");
      }

      // v41: verificar circuit breaker diario apos cada perda
      if(MaxPerdaDiaria_PCT > 0)
      {
         double perdaHoje   = GetLucroHoje();
         double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
         double limitePerda = equity * MaxPerdaDiaria_PCT / 100.0;

         if(perdaHoje < -limitePerda)
         {
            tradingBloqueadoHoje = true;
            Print("CIRCUIT BREAKER ATIVADO: perda dia=", NormalizeDouble(-perdaHoje,2),
                  " EUR (", NormalizeDouble(-perdaHoje/equity*100,2), "%) | limite=",
                  NormalizeDouble(limitePerda,2));
         }
      }
   }
   else
   {
      perdasConsecutivas = 0;
   }

   // cooldown normal por SL
   if(CooldownBarrasSL <= 0 || profit >= 0.0) return;

   ENUM_DEAL_TYPE tipo = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);

   // fechar compra gera deal SELL => cooldown BUY
   if(tipo == DEAL_TYPE_SELL)
   {
      cooldownCompra = CooldownBarrasSL;
      Print("COOLDOWN COMPRA: ", CooldownBarrasSL, " barras");
   }
   // fechar venda gera deal BUY => cooldown SELL
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
