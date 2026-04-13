CLASS zcl_bw_job_reader DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
    TYPES: tt_failed_jobs TYPE STANDARD TABLE OF zbtw_fail_job WITH DEFAULT KEY.

    METHODS:
      constructor,

      get_failed_jobs
        IMPORTING
          iv_lookback_min TYPE i DEFAULT 60
        RETURNING
          VALUE(rt_jobs)  TYPE tt_failed_jobs,

      get_failed_chains
        IMPORTING
          iv_lookback_min TYPE i DEFAULT 60
        RETURNING
          VALUE(rt_jobs)  TYPE tt_failed_jobs,

      get_failed_dtps
        IMPORTING
          iv_lookback_min TYPE i DEFAULT 60
        RETURNING
          VALUE(rt_jobs)  TYPE tt_failed_jobs.

  PRIVATE SECTION.
    METHODS:
      build_object_key
        IMPORTING
          iv_name       TYPE char100
          iv_count      TYPE char10
        RETURNING
          VALUE(rv_key) TYPE char100,

      get_priority
        IMPORTING
          iv_chain_name  TYPE char100
        RETURNING
          VALUE(rv_prio) TYPE char10,

      calc_from_timestamp
        IMPORTING
          iv_lookback_min   TYPE i
        RETURNING
          VALUE(rv_from_ts) TYPE timestamp.

ENDCLASS.


CLASS zcl_bw_job_reader IMPLEMENTATION.

  METHOD constructor.
    " No initialization required
  ENDMETHOD.


  METHOD get_failed_jobs.
    DATA: lt_tbtco TYPE STANDARD TABLE OF tbtco,
          lt_tbtcp TYPE SORTED TABLE OF tbtcp WITH NON-UNIQUE KEY jobname jobcount,
          ls_tbtco TYPE tbtco,
          ls_tbtcp TYPE tbtcp,
          ls_job   TYPE zbtw_fail_job,
          lv_date  TYPE sy-datum,
          lv_time  TYPE sy-uzeit.

    DATA(lv_from) = calc_from_timestamp( iv_lookback_min ).

    CONVERT TIME STAMP lv_from TIME ZONE sy-zonlo
      INTO DATE lv_date
           TIME lv_time.

    SELECT * FROM tbtco
      INTO TABLE lt_tbtco
      WHERE status   = 'A'
        AND strtdate >= lv_date.

    " Bulk-fetch all step logs in one query to avoid N+1 SELECT inside loop
    IF lt_tbtco IS NOT INITIAL.
      SELECT * FROM tbtcp
        INTO TABLE lt_tbtcp
        FOR ALL ENTRIES IN lt_tbtco
        WHERE jobname  = lt_tbtco-jobname
          AND jobcount = lt_tbtco-jobcount.
    ENDIF.

    LOOP AT lt_tbtco INTO ls_tbtco.
      CLEAR ls_job.
      ls_job-jobname    = ls_tbtco-jobname.
      ls_job-jobcount   = ls_tbtco-jobcount.
      ls_job-job_type   = 'BGDJOB'.
      ls_job-object_key = build_object_key(
                            iv_name  = |{ ls_tbtco-jobname }|
                            iv_count = |{ ls_tbtco-jobcount }| ).

      CONVERT DATE ls_tbtco-enddate
              TIME ls_tbtco-endtime
        TIME ZONE sy-zonlo
        INTO TIME STAMP ls_job-fail_tstamp.

      READ TABLE lt_tbtcp INTO ls_tbtcp
        WITH KEY jobname  = ls_tbtco-jobname
                 jobcount = ls_tbtco-jobcount.
      IF sy-subrc = 0.
        ls_job-error_msg = ls_tbtcp-dyndtext(255).
      ENDIF.

      ls_job-priority = get_priority( |{ ls_tbtco-jobname }| ).

      APPEND ls_job TO rt_jobs.
    ENDLOOP.
  ENDMETHOD.


  METHOD get_failed_chains.
    TYPES: BEGIN OF ty_logentry,
             logid   TYPE rspclogentry-logid,
             message TYPE rspclogentry-message,
           END OF ty_logentry.

    DATA: lt_chains     TYPE STANDARD TABLE OF rspclogchain,
          lt_logentries TYPE SORTED TABLE OF ty_logentry WITH NON-UNIQUE KEY logid,
          ls_chain      TYPE rspclogchain,
          ls_job        TYPE zbtw_fail_job.

    DATA(lv_from) = calc_from_timestamp( iv_lookback_min ).

    SELECT * FROM rspclogchain
      INTO TABLE lt_chains
      WHERE logstate IN ('E', 'A')
        AND starttime >= lv_from.

    " Bulk-fetch all error log entries in one query to avoid N+1 SELECT inside loop
    IF lt_chains IS NOT INITIAL.
      SELECT logid message FROM rspclogentry
        INTO CORRESPONDING FIELDS OF TABLE lt_logentries
        FOR ALL ENTRIES IN lt_chains
        WHERE logid    = lt_chains-logid
          AND severity = 'E'.
    ENDIF.

    LOOP AT lt_chains INTO ls_chain.
      CLEAR ls_job.
      ls_job-chain_id    = ls_chain-chain_id.
      ls_job-job_type    = 'CHAIN'.
      ls_job-fail_tstamp = ls_chain-starttime.
      ls_job-object_key  = build_object_key(
                             iv_name  = |{ ls_chain-chain_id }|
                             iv_count = |{ ls_chain-logid }| ).

      READ TABLE lt_logentries
        WITH KEY logid = ls_chain-logid
        INTO DATA(ls_entry).
      IF sy-subrc = 0.
        ls_job-error_msg = ls_entry-message.
      ENDIF.

      ls_job-priority = get_priority( |{ ls_chain-chain_id }| ).

      APPEND ls_job TO rt_jobs.
    ENDLOOP.
  ENDMETHOD.


  METHOD get_failed_dtps.
    DATA: lt_req TYPE STANDARD TABLE OF rsbkrequest,
          ls_req TYPE rsbkrequest,
          ls_job TYPE zbtw_fail_job.

    DATA(lv_from) = calc_from_timestamp( iv_lookback_min ).

    SELECT * FROM rsbkrequest
      INTO TABLE lt_req
      WHERE status    = 'E'
        AND timestamp >= lv_from.

    LOOP AT lt_req INTO ls_req.
      CLEAR ls_job.
      ls_job-jobname    = |{ ls_req-dtpname }|.
      ls_job-job_type   = 'DTP'.
      ls_job-fail_tstamp = ls_req-timestamp.
      ls_job-object_key  = build_object_key(
                             iv_name  = |{ ls_req-dtpname }|
                             iv_count = |{ ls_req-requid }| ).
      ls_job-error_msg   = ls_req-msgv1(255).
      ls_job-priority    = get_priority( |{ ls_req-dtpname }| ).

      APPEND ls_job TO rt_jobs.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_object_key.
    rv_key = |{ iv_name }_{ iv_count }|.
  ENDMETHOD.


  METHOD get_priority.
    DATA: lt_prio TYPE STANDARD TABLE OF zbwjob_priority,
          ls_prio TYPE zbwjob_priority.

    " Exact match first
    SELECT SINGLE * FROM zbwjob_priority
      INTO ls_prio
      WHERE chain_pattern = iv_chain_name
        AND active        = 'X'.
    IF sy-subrc = 0.
      rv_prio = ls_prio-priority.
      RETURN.
    ENDIF.

    " Wildcard match: entries containing * or +
    SELECT * FROM zbwjob_priority
      INTO TABLE lt_prio
      WHERE active = 'X'.

    LOOP AT lt_prio INTO ls_prio.
      IF iv_chain_name CP ls_prio-chain_pattern.
        rv_prio = ls_prio-priority.
        RETURN.
      ENDIF.
    ENDLOOP.

    " Default fallback
    rv_prio = 'MEDIUM'.
  ENDMETHOD.


  METHOD calc_from_timestamp.
    DATA(lv_seconds) = iv_lookback_min * 60.
    GET TIME STAMP FIELD DATA(lv_now).
    rv_from_ts = lv_now - lv_seconds.
  ENDMETHOD.

ENDCLASS.
