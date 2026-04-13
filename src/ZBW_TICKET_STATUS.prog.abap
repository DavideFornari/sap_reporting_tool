*&---------------------------------------------------------------------*
*& Report  ZBW_TICKET_STATUS
*& Monitor view for ZBTW_TICKET_LOG - ALV list with close action
*&---------------------------------------------------------------------*
REPORT zbw_ticket_status.

"----------------------------------------------------------------------
" Selection screen
"----------------------------------------------------------------------
PARAMETERS:
  p_dayfr TYPE dats DEFAULT sy-datum OBLIGATORY,
  p_dayto TYPE dats DEFAULT sy-datum OBLIGATORY.

SELECT-OPTIONS:
  s_status FOR zbtw_ticket_log-ticket_status DEFAULT 'OPEN'.

"----------------------------------------------------------------------
" Type definitions
"----------------------------------------------------------------------
TYPES: tt_ticket_log TYPE STANDARD TABLE OF zbtw_ticket_log WITH DEFAULT KEY.

"----------------------------------------------------------------------
" Module-level data (needed for ALV user command)
"----------------------------------------------------------------------
DATA: gt_log TYPE tt_ticket_log,
      go_alv TYPE REF TO cl_salv_table.

"----------------------------------------------------------------------
" Main processing
"----------------------------------------------------------------------
START-OF-SELECTION.

  SELECT * FROM zbtw_ticket_log
    INTO TABLE gt_log
    WHERE log_date      BETWEEN p_dayfr AND p_dayto
      AND ticket_status IN s_status
    ORDER BY log_date DESCENDING created_at DESCENDING.

  IF gt_log IS INITIAL.
    MESSAGE 'No ticket entries found for the selected criteria.' TYPE 'I'.
    RETURN.
  ENDIF.

  TRY.
      cl_salv_table=>factory(
        IMPORTING
          r_salv_table = go_alv
        CHANGING
          t_table      = gt_log ).

      " Optimize column widths automatically
      go_alv->get_columns( )->set_optimize( abap_true ).

      " Enable all standard ALV toolbar functions
      go_alv->get_functions( )->set_all( abap_true ).

      " Register user-command handler for the 'Close Ticket' button
      DATA(lo_events) = go_alv->get_event( ).
      SET HANDLER lcl_alv_events=>on_user_command FOR lo_events.

      " Add custom 'Close Ticket' function button to toolbar
      DATA(lo_functions) = go_alv->get_functions( ).
      lo_functions->add_function(
        name     = 'CLOSE_TICKET'
        icon     = '@0L@'
        text     = 'Close Ticket'
        tooltip  = 'Set selected ticket(s) to CLOSED'
        position = cl_salv_function_settings=>c_position_right ).

      go_alv->display( ).

    CATCH cx_salv_msg INTO DATA(lx_salv).
      MESSAGE lx_salv->get_text( ) TYPE 'I'.
    CATCH cx_salv_not_found INTO DATA(lx_nf).
      MESSAGE lx_nf->get_text( ) TYPE 'I'.
  ENDTRY.

"----------------------------------------------------------------------
" Local class: ALV event handler
"----------------------------------------------------------------------
CLASS lcl_alv_events DEFINITION.
  PUBLIC SECTION.
    CLASS-METHODS:
      on_user_command
        FOR EVENT added_function OF cl_salv_events_actions_table
        IMPORTING e_salv_function.
ENDCLASS.

CLASS lcl_alv_events IMPLEMENTATION.
  METHOD on_user_command.
    CHECK e_salv_function = 'CLOSE_TICKET'.

    " Iterate selected rows and set status to CLOSED
    DATA: lo_selections TYPE REF TO cl_salv_selections,
          lt_rows       TYPE salv_t_row,
          lv_index      TYPE i,
          ls_log        TYPE zbtw_ticket_log,
          lv_ts         TYPE timestamp.

    lo_selections = go_alv->get_selections( ).
    lt_rows       = lo_selections->get_selected_rows( ).

    IF lt_rows IS INITIAL.
      MESSAGE 'Please select at least one row.' TYPE 'I'.
      RETURN.
    ENDIF.

    GET TIME STAMP FIELD lv_ts.

    LOOP AT lt_rows INTO lv_index.
      READ TABLE gt_log INDEX lv_index INTO ls_log.
      CHECK sy-subrc = 0.

      UPDATE zbtw_ticket_log
        SET ticket_status = 'CLOSED'
            updated_at    = lv_ts
        WHERE object_key = ls_log-object_key.

      ls_log-ticket_status = 'CLOSED'.
      ls_log-updated_at    = lv_ts.
      MODIFY gt_log FROM ls_log INDEX lv_index.
    ENDLOOP.

    COMMIT WORK.

    " Refresh ALV display to reflect status changes
    go_alv->refresh( ).

    MESSAGE |{ lines( lt_rows ) } ticket(s) closed.| TYPE 'I'.
  ENDMETHOD.
ENDCLASS.
