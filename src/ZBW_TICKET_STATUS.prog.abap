*&---------------------------------------------------------------------*
*& Report  ZBW_TICKET_STATUS
*& Monitor view per ZBTW_TICKET_LOG — lista ALV con azione di chiusura
*&
*& Scopo:
*&   Report interattivo che mostra i ticket registrati in ZBTW_TICKET_LOG
*&   filtrabili per data e stato. Fornisce un pulsante personalizzato
*&   "Close Ticket" nella toolbar ALV per chiudere manualmente i ticket
*&   selezionati senza accedere al sistema di ticketing esterno.
*&
*& Uso tipico:
*&   - Monitoraggio giornaliero degli incident aperti
*&   - Chiusura manuale di ticket risolti fuori banda
*&   - Verifica dello stato di sincronizzazione con il sistema esterno
*&
*& Dipendenze:
*&   ZBTW_TICKET_LOG — tabella di deduplication e log
*&   CL_SALV_TABLE   — framework ALV OO
*&---------------------------------------------------------------------*
REPORT zbw_ticket_status.

"----------------------------------------------------------------------
" Selection screen
"----------------------------------------------------------------------
PARAMETERS:
  p_dayfr TYPE dats DEFAULT sy-datum OBLIGATORY,   " data inizio filtro
  p_dayto TYPE dats DEFAULT sy-datum OBLIGATORY.   " data fine filtro

SELECT-OPTIONS:
  " Filtro sullo stato del ticket — default: solo OPEN.
  " L'operatore permette selezioni multiple (es. OPEN, UPDATED).
  s_status FOR zbtw_ticket_log-ticket_status DEFAULT 'OPEN'.

"----------------------------------------------------------------------
" Definizioni di tipo
"----------------------------------------------------------------------
TYPES: tt_ticket_log TYPE STANDARD TABLE OF zbtw_ticket_log WITH DEFAULT KEY.

"----------------------------------------------------------------------
" Variabili globali — necessarie per l'handler eventi ALV (LCL_ALV_EVENTS)
" che viene chiamato fuori dal blocco START-OF-SELECTION.
"----------------------------------------------------------------------
DATA: gt_log TYPE tt_ticket_log,    " dati mostrati nella griglia ALV
      go_alv TYPE REF TO cl_salv_table.  " istanza ALV — usata anche nell'handler

"----------------------------------------------------------------------
" Main processing
"----------------------------------------------------------------------
START-OF-SELECTION.

  " Legge i ticket che rientrano nei criteri della selection screen.
  " Ordinamento: prima per data più recente, poi per timestamp creazione.
  SELECT * FROM zbtw_ticket_log
    INTO TABLE gt_log
    WHERE log_date      BETWEEN p_dayfr AND p_dayto
      AND ticket_status IN s_status
    ORDER BY log_date DESCENDING created_at DESCENDING.

  " Se nessun record trovato, informa l'utente e termina.
  IF gt_log IS INITIAL.
    MESSAGE 'No ticket entries found for the selected criteria.' TYPE 'I'.
    RETURN.
  ENDIF.

  TRY.
      " Crea la griglia ALV a partire dalla tabella GT_LOG.
      " FACTORY crea internamente l'istanza e la collega alla tabella.
      cl_salv_table=>factory(
        IMPORTING
          r_salv_table = go_alv
        CHANGING
          t_table      = gt_log ).

      " Ottimizza automaticamente la larghezza di ogni colonna
      " in base al contenuto e alle intestazioni.
      go_alv->get_columns( )->set_optimize( abap_true ).

      " Abilita tutte le funzioni standard della toolbar ALV:
      " ordinamento, filtraggio, export Excel/PDF, layout, ecc.
      go_alv->get_functions( )->set_all( abap_true ).

      " Registra l'handler per gli eventi utente personalizzati.
      " Ogni click su un pulsante custom della toolbar scatena l'evento
      " ADDED_FUNCTION — gestito da LCL_ALV_EVENTS=>ON_USER_COMMAND.
      DATA(lo_events) = go_alv->get_event( ).
      SET HANDLER lcl_alv_events=>on_user_command FOR lo_events.

      " Aggiunge il pulsante personalizzato "Close Ticket" nella toolbar destra.
      DATA(lo_functions) = go_alv->get_functions( ).
      lo_functions->add_function(
        name     = 'CLOSE_TICKET'          " codice funzione ricevuto in ON_USER_COMMAND
        icon     = '@0L@'                  " icona SAP standard (simbolo 'chiudi')
        text     = 'Close Ticket'
        tooltip  = 'Set selected ticket(s) to CLOSED'
        position = cl_salv_function_settings=>c_position_right ).

      " Visualizza la griglia ALV — dopo questo punto il controllo passa al framework.
      go_alv->display( ).

    CATCH cx_salv_msg INTO DATA(lx_salv).
      " Errore nel framework ALV (es. tabella vuota, problema di layout).
      MESSAGE lx_salv->get_text( ) TYPE 'I'.
    CATCH cx_salv_not_found INTO DATA(lx_nf).
      " Errore interno ALV (funzione o componente non trovato).
      MESSAGE lx_nf->get_text( ) TYPE 'I'.
  ENDTRY.

"----------------------------------------------------------------------
" Classe locale: handler per gli eventi utente della toolbar ALV
"
" Scopo:
"   Intercetta il click sul pulsante "Close Ticket" e aggiorna
"   lo stato delle righe selezionate in ZBTW_TICKET_LOG.
"
"   La classe è dichiarata DOPO lo START-OF-SELECTION per rispettare
"   la sequenza di definizione dei simboli in un report ABAP (le variabili
"   globali GT_LOG e GO_ALV devono essere visibili nell'implementazione).
"----------------------------------------------------------------------
CLASS lcl_alv_events DEFINITION.
  PUBLIC SECTION.
    CLASS-METHODS:
      "! Handler per l'evento ADDED_FUNCTION della toolbar ALV.
      "! Viene chiamato ogni volta che l'utente clicca un pulsante custom.
      "! Il parametro E_SALV_FUNCTION contiene il codice del pulsante premuto.
      on_user_command
        FOR EVENT added_function OF cl_salv_events_actions_table
        IMPORTING e_salv_function.
ENDCLASS.

CLASS lcl_alv_events IMPLEMENTATION.
  METHOD on_user_command.
    " Filtra: reagisce solo al pulsante 'CLOSE_TICKET'.
    " Altri pulsanti custom (eventuali future aggiunte) vengono ignorati.
    CHECK e_salv_function = 'CLOSE_TICKET'.

    DATA: lo_selections TYPE REF TO cl_salv_selections,
          lt_rows       TYPE salv_t_row,    " tabella di indici di riga selezionati
          lv_index      TYPE i,
          ls_log        TYPE zbtw_ticket_log,
          lv_ts         TYPE timestamp.

    " Recupera le righe selezionate dall'utente nella griglia ALV.
    lo_selections = go_alv->get_selections( ).
    lt_rows       = lo_selections->get_selected_rows( ).

    " Se nessuna riga è selezionata, mostra un messaggio e termina.
    IF lt_rows IS INITIAL.
      MESSAGE 'Please select at least one row.' TYPE 'I'.
      RETURN.
    ENDIF.

    " Timestamp corrente per UPDATED_AT — lo stesso per tutte le righe chiuse in questo batch.
    GET TIME STAMP FIELD lv_ts.

    " Itera gli indici delle righe selezionate.
    LOOP AT lt_rows INTO lv_index.
      " Legge il record corrispondente dalla tabella di dati GT_LOG (in memoria).
      READ TABLE gt_log INDEX lv_index INTO ls_log.
      CHECK sy-subrc = 0.  " salto righe con indice non valido (non dovrebbe accadere)

      " Aggiorna il record in ZBTW_TICKET_LOG.
      " WHERE su OBJECT_KEY (chiave primaria): nessun filtro su LOG_DATE,
      " che non è più parte della chiave primaria dopo il fix "Midnight Duplicate".
      UPDATE zbtw_ticket_log
        SET ticket_status = 'CLOSED'
            updated_at    = lv_ts
        WHERE object_key = ls_log-object_key.

      " Aggiorna anche la copia in memoria (GT_LOG) per coerenza con la griglia.
      " Senza questo, GO_ALV->REFRESH() mostrerebbe valori vecchi.
      ls_log-ticket_status = 'CLOSED'.
      ls_log-updated_at    = lv_ts.
      MODIFY gt_log FROM ls_log INDEX lv_index.
    ENDLOOP.

    " Emette un solo COMMIT WORK per tutte le righe chiuse nel batch.
    " Farlo una volta sola (non per ogni riga) è più efficiente e garantisce
    " che tutte le modifiche vengano persistite atomicamente.
    COMMIT WORK.

    " Aggiorna la griglia ALV per mostrare il nuovo stato CLOSED.
    go_alv->refresh( ).

    " Messaggio di conferma con il numero di ticket chiusi.
    MESSAGE |{ lines( lt_rows ) } ticket(s) closed.| TYPE 'I'.
  ENDMETHOD.
ENDCLASS.
