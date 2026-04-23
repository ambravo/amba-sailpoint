*&---------------------------------------------------------------------*
*& Report  ZAUTH_TO_SAILPOINT
*& Demo: mini vendor-invoice screen. On AUTHORITY-CHECK failure the
*&       user is offered (popup) to auto-request access via SailPoint
*&       ISC instead of dying with an error message.
*&
*& Flow (no dynpros painted - selection screen + popup FMs only):
*&   1. Selection screen: BUKRS / LIFNR / XBLNR / WRBTR / WAERS
*&   2. F8 Execute -> START-OF-SELECTION
*&         AUTHORITY-CHECK F_BKPF_BUK / BUKRS / ACTVT=01
*&         pass -> MESSAGE 'S' (invoice posted)
*&         fail -> POPUP_TO_CONFIRM "Request access via SailPoint?"
*&                   yes -> OAuth + POST /v3/access-requests
*&                          POPUP_TO_INFORM (request id or error)
*&                   no  -> LEAVE PROGRAM
*&---------------------------------------------------------------------*
REPORT zauth_to_sailpoint.

*----------------------------------------------------------------------*
* Constants (in prod: read from a config table or STRUST/SSF)
*----------------------------------------------------------------------*
CONSTANTS:
  c_tenant_api  TYPE string VALUE 'https://company21824-poc.api.identitynow-demo.com',
  c_client_id   TYPE string VALUE '43a4f8cd5fca43e1ac891ac9f5b9d711',
  c_client_sec  TYPE string VALUE '<<INJECT_AT_RUNTIME>>',
  c_identity_id TYPE string VALUE '2c9180857aaaaaaaaaaaaaaaaaaaaaaa',
  c_ap_id       TYPE string VALUE '2c9180857bbbbbbbbbbbbbbbbbbbbbbb'.

*----------------------------------------------------------------------*
* Selection screen: FB60 header lookalike
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-t01.
  PARAMETERS:
    p_bukrs TYPE bukrs DEFAULT '1000'         OBLIGATORY,
    p_lifnr TYPE lifnr DEFAULT '0000100001'   OBLIGATORY,
    p_xblnr TYPE xblnr DEFAULT 'INV-2026-0423',
    p_wrbtr TYPE wrbtr DEFAULT '1250.00',
    p_waers TYPE waers DEFAULT 'EUR'.
SELECTION-SCREEN END OF BLOCK b1.

DATA: gv_token TYPE string,
      gv_reqid TYPE string,
      gv_http  TYPE i.

*----------------------------------------------------------------------*
START-OF-SELECTION.

  AUTHORITY-CHECK OBJECT 'F_BKPF_BUK'
    ID 'BUKRS' FIELD p_bukrs
    ID 'ACTVT' FIELD '01'.

  IF sy-subrc = 0.
    MESSAGE |Invoice { p_xblnr } posted in BUKRS { p_bukrs } | &&
            |(vendor { p_lifnr }, { p_wrbtr } { p_waers })|
            TYPE 'S'.
    RETURN.
  ENDIF.

  PERFORM offer_sailpoint_request.

*&---------------------------------------------------------------------*
FORM offer_sailpoint_request.
  DATA: lv_answer   TYPE c LENGTH 1,
        lv_question TYPE string,
        lv_l1       TYPE char70,
        lv_l2       TYPE char70,
        lv_l3       TYPE char70,
        lv_l4       TYPE char70.

  lv_question = |No authorization for company code { p_bukrs } | &&
                |(auth object F_BKPF_BUK, activity 01).| &&
                | Request access via SailPoint ISC?|.

  CALL FUNCTION 'POPUP_TO_CONFIRM'
    EXPORTING
      titlebar              = 'SAP - Access Denied'
      text_question         = lv_question
      text_button_1         = 'Request'
      icon_button_1         = 'ICON_OKAY'
      text_button_2         = 'Cancel'
      icon_button_2         = 'ICON_CANCEL'
      default_button        = '1'
      display_cancel_button = ' '
    IMPORTING
      answer                = lv_answer
    EXCEPTIONS
      text_not_found        = 1
      OTHERS                = 2.

  IF sy-subrc <> 0 OR lv_answer <> '1'.
    RETURN.
  ENDIF.

  PERFORM get_oauth_token CHANGING gv_token.
  IF gv_token IS INITIAL.
    lv_l1 = 'OAuth to SailPoint failed.'.
    lv_l2 = 'Check client_id / client_secret / tenant URL.'.
    CALL FUNCTION 'POPUP_TO_INFORM'
      EXPORTING titel = 'SailPoint'
                txt1  = lv_l1
                txt2  = lv_l2.
    RETURN.
  ENDIF.

  PERFORM submit_request USING    gv_token
                         CHANGING gv_reqid gv_http.

  IF gv_http = 200 OR gv_http = 201 OR gv_http = 202.
    lv_l1 = |SailPoint accepted the request (HTTP { gv_http }).|.
    lv_l2 = |Request ID: { gv_reqid }|.
    lv_l3 = |Identity:   { c_identity_id }|.
    lv_l4 = |Access prof: { c_ap_id }|.
  ELSEIF gv_http = 429.
    lv_l1 = 'SailPoint rate limit hit (HTTP 429).'.
    lv_l2 = 'Retry-After header carries back-off hint.'.
    lv_l3 = 'Volume anomaly may trigger SailPoint workflow.'.
    lv_l4 = ''.
  ELSE.
    lv_l1 = |SailPoint rejected the request (HTTP { gv_http }).|.
    lv_l2 = 'See SM21 / ST22 for full response body.'.
    lv_l3 = ''.
    lv_l4 = ''.
  ENDIF.

  CALL FUNCTION 'POPUP_TO_INFORM'
    EXPORTING titel = 'SailPoint ISC'
              txt1  = lv_l1
              txt2  = lv_l2
              txt3  = lv_l3
              txt4  = lv_l4.
ENDFORM.

*======================================================================*
*  SailPoint ISC helpers
*======================================================================*
FORM get_oauth_token CHANGING cv_token TYPE string.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  lv_url = |{ c_tenant_api }/oauth/token|.

  cl_http_client=>create_by_url(
    EXPORTING url    = lv_url
    IMPORTING client = lo_http ).

  lo_http->request->set_method( 'POST' ).
  lo_http->request->set_header_field(
    name = 'Content-Type' value = 'application/x-www-form-urlencoded' ).

  lv_body = |grant_type=client_credentials|      &&
            |&client_id={ c_client_id }|         &&
            |&client_secret={ c_client_sec }|.
  lo_http->request->set_cdata( lv_body ).

  lo_http->send( ).
  lo_http->receive( ).
  lo_http->response->get_status( IMPORTING code = lv_code ).
  lv_resp = lo_http->response->get_cdata( ).

  IF lv_code <> 200.
    CLEAR cv_token.
    RETURN.
  ENDIF.

  " Crude JSON parse. In real Z code use /UI2/CL_JSON.
  FIND REGEX '"access_token"\s*:\s*"([^"]+)"'
       IN lv_resp SUBMATCHES cv_token.
ENDFORM.

FORM submit_request USING    iv_token TYPE string
                    CHANGING cv_reqid TYPE string
                             cv_http  TYPE i.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string.

  lv_url = |{ c_tenant_api }/v3/access-requests|.

  lv_body =
    |\{| &&
      |"requestedFor":["{ c_identity_id }"],| &&
      |"requestType":"GRANT_ACCESS",| &&
      |"requestedItems":[\{| &&
        |"type":"ACCESS_PROFILE",| &&
        |"id":"{ c_ap_id }",| &&
        |"comment":"Auto-requested from SAP tx FB60 after AUTHORITY-CHECK failure on F_BKPF_BUK",| &&
        |"clientMetadata":\{| &&
          |"sourceSystem":"SAP-PRD",| &&
          |"tcode":"FB60",| &&
          |"authObject":"F_BKPF_BUK",| &&
          |"triggeredBy":"ZAUTH_TO_SAILPOINT"| &&
        |\}| &&
      |\}]| &&
    |\}|.

  cl_http_client=>create_by_url(
    EXPORTING url    = lv_url
    IMPORTING client = lo_http ).

  lo_http->request->set_method( 'POST' ).
  lo_http->request->set_header_field(
    name = 'Authorization' value = |Bearer { iv_token }| ).
  lo_http->request->set_header_field(
    name = 'Content-Type'  value = 'application/json' ).
  lo_http->request->set_cdata( lv_body ).

  lo_http->send( ).
  lo_http->receive( ).
  lo_http->response->get_status( IMPORTING code = cv_http ).
  lv_resp = lo_http->response->get_cdata( ).

  CLEAR cv_reqid.
  IF cv_http = 200 OR cv_http = 201 OR cv_http = 202.
    FIND REGEX '"id"\s*:\s*"([^"]+)"'
         IN lv_resp SUBMATCHES cv_reqid.
  ENDIF.
ENDFORM.
