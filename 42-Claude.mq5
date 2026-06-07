//+------------------------------------------------------------------+
//|                     EA Falha Exaustao v42.0                      |
//|  Crystal Heikin Ashi | BUY-only | Risco Dinamico | USDJPY M5     |
//+------------------------------------------------------------------+
//
//  DIAGNOSTICO v41 (300 trades, 2025.01-2026.06):
//  - Lucro liquido: -1.681 EUR (PREJUIZO)
//  - Max DD: 39.83% — IGUAL ao v31 apesar do risco dinamico
//  - PF: 0.91 | Payoff ratio: 0.93 (avg win 110 < avg loss 118)
//
//  POR QUE v41 FALHOU:
//  [A] SELL destroiu tudo: 81 trades a 29.63% win => EV = -50 EUR/trade
//      => -4.050 EUR so do SELL. Nem MA50D1 + H4 foram suficientes.
//  [B] Parcial TP em 1xRR prejudicou payoff: fechar 50% ao 1:1 e mover
//      BE reduz muito o ganho medio sem reduzir a perda media.
//      Resultado: avg win (110) < avg loss (118) => payoff < 1.
//  [C] Circuit breaker diario nao previne DD semanal: 3%/dia × 10
//      dias ruins consecutivos = 30% de DD possivel.
//
//  SOLUCAO v42 — CRYSTAL HEIKIN ASHI:
//
//  [1] NOVO SINAL: Crystal Heikin Ashi
//      - BUY quando HA vira VERDE: HA_Close[1] > HA_Open[1]
//        E barra anterior era VERMELHA: HA_Close[2] <= HA_Open[2]
//      - SL abaixo do HA_Low[1] (minimo suavizado = nivel mais robusto)
//      - TP = entrada + risco * RiscoRetorno
//      Vantagens vs "Falha de Fundo" original:
//        a) HA suaviza o ruido de preco, menos sinais falsos
//        b) Sinal ja confirmado no fechamento da barra — sem necessidade
//           de esperar o "pavio" especifico
//        c) SL no HA_Low e mais longe de wickes individuais => menos
//           stops prematuros
//
//  [2] SELL PERMANENTEMENTE DESABILITADO
//      Historico confirma: USDJPY 2025-2026 e bull market estrutural.
//      29.63% win rate (v41), 25.91% (v30) — inviavel em qualquer versao.
//
//  [3] PARCIAL TP AJUSTADO: RR = 1.5 (era 1.0)
//      Ao fechar 50% em 1.5xRR (vs 1.0 antes), o ganho medio aumenta
//      significativamente. EV positivo exige avg win > avg loss.
//
//  [4] CIRCUIT BREAKER SEMANAL (novo):
//      Alem do diario (3%), novo limite semanal (8%).
//      Evita que dias ruins se acumulem sem protecao.
//
//  CONFIGURACAO DOS BUFFERS DO CRYSTAL HEIKIN ASHI:
//      Layout padrao (ajuste se necessario apos inspecionar no tester):
//      Buffer 0 = HA_Open  | Buffer 1 = HA_High
//      Buffer 2 = HA_Low   | Buffer 3 = HA_Close
//      Dica: no tester, abra o grafico com o indicador e verifique
//      os valores de cada buffer no indicador Data Window.
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

input group "=== CRYSTAL HEIKIN ASHI ==="
input string HA_NomeIndicador        = "Market\\Crystal Heikin Ashi"; // Caminho: Market\Crystal Heikin Ashi
input int    HA_Buffer_Open          = 0;    // Buffer do HA Open
input int    HA_Buffer_High          = 1;    // Buffer do HA High
input int    HA_Buffer_Low           = 2;    // Buffer do HA Low
input int    HA_Buffer_Close         = 3;    // Buffer do HA Close
input int    HA_ConfirmacaoBarras    = 1;    // Barras de confirmacao (1=flip na barra anterior)

input group "=== GESTAO DE RISCO DINAMICA ==="
input bool   UsarRiscoDinamico       = true;
input double RiscoPerTrade_PCT       = 1.5;  // 1.5%: meta ~4%/mes, DD estimado <15%
input double LoteFixo                = 3.5;  // Lote fixo (UsarRiscoDinamico=false)
input double MaxLote                 = 5.0;  // Teto absoluto de lote
input double RiscoRetorno            = 2.0;  // TP = entrada + risco * 2.0

input group "=== PARCIAL TP + BREAKEVEN ==="
input bool   UsarParcialTP           = true;
input double ParcialTP_RR            = 1.5;  // v42: 1.5 (era 1.0) — melhora payoff ratio
input double ParcialTP_Volume_PCT    = 50.0;

input group "=== CIRCUIT BREAKERS ==="
input double MaxPerdaDiaria_PCT      = 3.0;  // Para no dia se perda > X% equity
input double MaxPerdaSemanal_PCT     = 8.0;  // Para na semana se perda > X% equity (0=off)
input int    MaxPerdasConsecutivas   = 5;
input int    CooldownPerdasConsec    = 30;

input group "=== THRESHOLDS EM ATR ==="
input double SL_Folga_ATR            = 0.15; // Folga abaixo do HA_Low para SL
input double MaxSLDistanciaATR       = 3.0;  // Teto: ignora sinal se SL > 3xATR
input double MinSLDistanciaATR       = 0.3;  // Piso: ignora sinal se SL < 0.3xATR (lote enorme)

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
input bool   UsarFiltroMA200          = true;  // BUY: MA20 > MA200

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
int hMA200, hMA20, hATR, hATR_Longo, hMA_H4, hHA;

//==================================================================
//  FLOORS
//==================================================================
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

   gSL_Folga_ATR = MathMax(SL_Folga_ATR, 0.05);

   Print("v42 Crystal HA | Risco:",
         (UsarRiscoDinamico ? DoubleToString(RiscoPerTrade_PCT,1)+"%" : "fixo "+DoubleToString(LoteFixo,2)),
         " | MaxLote:", MaxLote,
         " | ParcialTP RR:", ParcialTP_RR,
         " | CBdiario:", MaxPerdaDiaria_PCT, "%",
         " | CBsemanal:", MaxPerdaSemanal_PCT, "%",
         " | FiltroH4:", (UsarFiltroTendenciaH4 ? "ON" : "OFF"),
         " | FiltroVol:", (UsarFiltroVolatilidade ? "ON" : "OFF"),
         " | HA:", HA_NomeIndicador,
         " [", HA_Buffer_Open, "/", HA_Buffer_High, "/", HA_Buffer_Low, "/", HA_Buffer_Close, "]");

   hMA200     = iMA  (_Symbol, _Period,   MA200_Period,    0, MODE_SMA, PRICE_CLOSE);
   hMA20      = iMA  (_Symbol, _Period,   MA20_Period,     0, MODE_SMA, PRICE_CLOSE);
   hATR       = iATR (_Symbol, _Period,   ATR_Periodo);
   hATR_Longo = iATR (_Symbol, _Period,   ATR_Longo_Periodo);
   hMA_H4     = iMA  (_Symbol, PERIOD_H4, MA_H4_Period,   0, MODE_SMA, PRICE_CLOSE);
   hHA        = iCustom(_Symbol, _Period, HA_NomeIndicador);

   if(hMA200 == INVALID_HANDLE || hMA20  == INVALID_HANDLE ||
      hATR   == INVALID_HANDLE || hATR_Longo == INVALID_HANDLE ||
      hMA_H4 == INVALID_HANDLE)
   {
      Print("ERRO v42: falha ao criar handle de indicador.");
      return INIT_FAILED;
   }

   if(hHA == INVALID_HANDLE)
   {
      Print("ERRO v42: Crystal Heikin Ashi nao encontrado. Verifique HA_NomeIndicador='",
            HA_NomeIndicador, "'");
      Print("Dica: verifique o nome exato no Navegador -> Indicadores -> Market");
      return INIT_FAILED;
   }

   Print("v42: Crystal Heikin Ashi carregado com sucesso.");
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
   IndicatorRelease(hHA);
}

//+------------------------------------------------------------------+
// Ler buffer especifico do Crystal Heikin Ashi
//+------------------------------------------------------------------+
double GetHA(int bufferIdx, int barIdx)
{
   double buf[1];
   if(CopyBuffer(hHA, bufferIdx, barIdx, 1, buf) > 0) return buf[0];
   return 0.0;
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

      // --- CRYSTAL HEIKIN ASHI ---
      // Barra confirmada [1] e barra anterior [2]
      int barSinal = HA_ConfirmacaoBarras;       // default=1 (barra fechada mais recente)
      int barAntes = HA_ConfirmacaoBarras + 1;   // barra anterior ao sinal

      double ha_open_s  = GetHA(HA_Buffer_Open,  barSinal);
      double ha_close_s = GetHA(HA_Buffer_Close, barSinal);
      double ha_high_s  = GetHA(HA_Buffer_High,  barSinal);
      double ha_low_s   = GetHA(HA_Buffer_Low,   barSinal);
      double ha_open_a  = GetHA(HA_Buffer_Open,  barAntes);
      double ha_close_a = GetHA(HA_Buffer_Close, barAntes);

      if(ha_open_s <= 0 || ha_close_s <= 0 || ha_low_s <= 0 || ha_high_s <= 0) return;
      if(ha_open_a <= 0 || ha_close_a <= 0) return;

      bool ha_verde_s    = (ha_close_s > ha_open_s);   // barra sinal: bullish
      bool ha_vermelho_s = (ha_close_s < ha_open_s);   // barra sinal: bearish
      bool ha_verde_a    = (ha_close_a > ha_open_a);   // barra anterior: bullish
      bool ha_vermelho_a = (ha_close_a < ha_open_a);   // barra anterior: bearish

      // Sinal de compra: HA virou VERDE (anterior era vermelho ou neutro)
      bool sinal_compra = ha_verde_s && !ha_verde_a;

      // Sinal de venda: HA virou VERMELHO (anterior era verde ou neutro)
      bool sinal_venda  = ha_vermelho_s && !ha_vermelho_a;

      lastATR = atr;

      double slBuffer = atr * gSL_Folga_ATR;
      double gatOff   = atr * 0.05;  // pequena confirmacao acima/abaixo do fechamento HA
      double maxRisco = (MaxSLDistanciaATR > 0) ? atr * MaxSLDistanciaATR : 0.0;
      double minRisco = atr * MinSLDistanciaATR;

      //------------------------------------------------------------
      // SETUP DE COMPRA — Crystal HA vira verde
      //------------------------------------------------------------
      if(PermitirCompra && sinal_compra && tendencia_alta_h4)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 > ma200);
         bool ok_cd    = (cooldownCompra == 0);

         if(ok_MA200 && ok_cd)
         {
            double gatilho = ha_close_s + gatOff;
            double sl      = NormalizeDouble(ha_low_s - slBuffer, _Digits);
            double risco   = gatilho - sl;
            double tp      = (RiscoRetorno > 0)
                             ? NormalizeDouble(gatilho + risco * RiscoRetorno, _Digits)
                             : 0.0;

            bool ok_sl_max = (maxRisco <= 0) || (risco <= maxRisco);
            bool ok_sl_min = (risco >= minRisco);

            if(!ok_sl_max)
               Print("COMPRA ignorada (SL largo): ", NormalizeDouble(risco/atr,2), "xATR > ", MaxSLDistanciaATR);
            else if(!ok_sl_min)
               Print("COMPRA ignorada (SL estreito): ", NormalizeDouble(risco/atr,2), "xATR < ", MinSLDistanciaATR);
            else if(ValidarStops(gatilho, sl, ORDER_TYPE_BUY))
            {
               precoGatilho     = gatilho;
               precoStopLoss    = sl;
               precoTakeProfit  = tp;
               loteCalculado    = CalcularLote(gatilho, sl);
               setupCompraAtivo = true;
               Print("SETUP COMPRA (HA verde) | SL:", sl, " TP:", tp,
                     " Lote:", loteCalculado,
                     " HA_Low:", NormalizeDouble(ha_low_s,3),
                     " risco:", NormalizeDouble(risco/atr,2), "xATR",
                     " MA20:", NormalizeDouble(ma20,3), " MA200:", NormalizeDouble(ma200,3));
            }
         }
      }

      //------------------------------------------------------------
      // SETUP DE VENDA — Crystal HA vira vermelho (desabilitado)
      //------------------------------------------------------------
      if(PermitirVenda && sinal_venda && !tendencia_alta_h4)
      {
         bool ok_MA200 = !UsarFiltroMA200 || (ma20 < ma200);
         bool ok_cd    = (cooldownVenda == 0);

         if(ok_MA200 && ok_cd)
         {
            double gatilho = ha_close_s - gatOff;
            double sl      = NormalizeDouble(ha_high_s + slBuffer, _Digits);
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
                     " Lote:", loteCalculado,
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
         trade.Buy(loteCalculado, _Symbol, ask, precoStopLoss, precoTakeProfit, "Crystal HA v42");
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
         trade.Sell(loteCalculado, _Symbol, bid, precoStopLoss, precoTakeProfit, "Crystal HA v42");
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

      // mover BE primeiro (protege risco na posicao restante)
      double newSL = NormalizeDouble(abertura, _Digits);
      trade.PositionModify(ticket, newSL, tpPos);
      Print("BREAKEVEN COMPRA: SL=", newSL,
            " | RR=", NormalizeDouble((bid-abertura)/riscoPreco,2));

      // fechar parcial
      double volume    = PositionGetDouble(POSITION_VOLUME);
      double volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double volParcial = MathFloor(volume * ParcialTP_Volume_PCT / 100.0 / volStep) * volStep;
      if(volParcial < volMin) volParcial = volMin;
      if(volParcial >= volume) continue;

      if(trade.PositionClosePartial(ticket, volParcial))
         Print("PARCIAL COMPRA: ", volParcial, " lotes | restante:",
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
         Print("CB DIARIO: perda=", NormalizeDouble(-perdaHoje,2), " EUR (",
               NormalizeDouble(-perdaHoje/equity*100,2), "%) > limite=",
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

   // reset na segunda-feira ou na primeira barra
   bool novaSemanaBool = (ultimaSemanaVerificada == 0);
   if(!novaSemanaBool && (dt.year != dtUlt.year || dt.day_of_week < dtUlt.day_of_week))
      novaSemanaBool = true;
   if(!novaSemanaBool && dt.mon != dtUlt.mon && dt.day_of_week == 1)
      novaSemanaBool = true;

   if(dt.day_of_week == 1 && dtUlt.day_of_week != 1)
      novaSemanaBool = true;

   if(!novaSemanaBool) return;

   ultimaSemanaVerificada = barAtual;
   tradingBloqueadoSemana = false;

   double perdaSemana = GetLucroSemana();
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double limite      = equity * MaxPerdaSemanal_PCT / 100.0;
   if(perdaSemana < -limite)
   {
      tradingBloqueadoSemana = true;
      Print("CB SEMANAL: perda=", NormalizeDouble(-perdaSemana,2), " EUR (",
            NormalizeDouble(-perdaSemana/equity*100,2), "%) > limite=",
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
   // voltar ate segunda-feira
   int diasDesdeSegunda = (dt.day_of_week == 0) ? 6 : dt.day_of_week - 1;
   datetime semanaInicio = TimeCurrent() - diasDesdeSegunda * 86400;
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
         Print("PAUSA CONSECUTIVA: ", MaxPerdasConsecutivas, " perdas -> cooldown ",
               CooldownPerdasConsec, " barras");
      }

      if(MaxPerdaDiaria_PCT > 0)
      {
         double perdaHoje = GetLucroHoje();
         double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
         if(perdaHoje < -(equity * MaxPerdaDiaria_PCT / 100.0))
         {
            tradingBloqueadoHoje = true;
            Print("CB DIARIO ATIVADO: perda=", NormalizeDouble(-perdaHoje,2), " EUR");
         }
      }

      if(MaxPerdaSemanal_PCT > 0)
      {
         double perdaSemana = GetLucroSemana();
         double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
         if(perdaSemana < -(equity * MaxPerdaSemanal_PCT / 100.0))
         {
            tradingBloqueadoSemana = true;
            Print("CB SEMANAL ATIVADO: perda semana=", NormalizeDouble(-perdaSemana,2), " EUR");
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
