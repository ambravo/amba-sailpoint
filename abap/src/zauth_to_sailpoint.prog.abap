*&---------------------------------------------------------------------*
*& Report  ZAUTH_TO_SAILPOINT
*& Demo: mini vendor-invoice transaction. On AUTHORITY-CHECK failure,
*&       dialog flow pivots to a SailPoint access request instead of
*&       dying with a short dump / error message.
*&
*& Screen flow:
*&   0100  Invoice entry        (mimics FB60 header)
*&     --> POST pressed, AUTHORITY-CHECK on F_BKPF_BUK
*&           sy-subrc = 0  -> leave to list, "posted" message
*&           sy-subrc <> 0 -> LEAVE TO SCREEN 0200
*&   0200  Access denied dialog (shows error + "Request access" button)
*&     --> REQ pressed -> call OAuth + POST /v3/access-requests
*&                        LEAVE TO SCREEN 0300
*&     --> CAN pressed -> LEAVE PROGRAM
*&   0300  Confirmation         (shows SailPoint request id + HTTP code)
*&     --> BACK -> LEAVE PROGRAM
*&
*& NOTE: the three dynpros (0100/0200/0300) and their GUI statuses
*&       (STATUS_0100 / STATUS_0200 / STATUS_0300) must be created in
*&       SE51 / SE80 inside the report. Field list + PF-STATUS hints
*&       are documented below each MODULE.
*&---------------------------------------------------------------------*
REPORT zauth_to_sailpoint.

*----------------------------------------------------------------------*
* Constants (in prod: read from a custom config table or STRUST/SSF)
*----------------------------------------------------------------------*
CONSTANTS:
  c_tenant_api  TYPE string VALUE 'https://company21824-poc.api.identitynow-demo.com',
  c_client_id   TYPE string VALUE '43a4f8cd5fca43e1ac891ac9f5b9d711',
  c_client_sec  TYPE string VALUE '<<INJECT_AT_RUNTIME>>',
  c_identity_id TYPE string VALUE '2c9180857aaaaaaaaaaaaaaaaaaaaaaa',
  c_ap_id       TYPE string VALUE '2c9180857bbbbbbbbbbbbbbbbbbbbbbb'.

*----------------------------------------------------------------------*
* Screen fields (declared so the dynpro painter can bind to them)
*----------------------------------------------------------------------*
DATA:
  gv_bukrs    TYPE bukrs  VALUE '1000',     " company code (screen 0100)
  gv_lifnr    TYPE lifnr  VALUE '0000100001',
  gv_wrbtr    TYPE wrbtr  VALUE '1250.00',
  gv_waers    TYPE waers  VALUE 'EUR',
  gv_xblnr    TYPE xblnr  VALUE 'INV-2026-0423',
  gv_errtxt   TYPE string,                  " screen 0200 error line
  gv_reqid    TYPE string,                  " screen 0300 request id
  gv_http     TYPE i,                       " screen 0300 http status
  gv_token    TYPE string,
  gv_ok_code  TYPE sy-ucomm,
  gv_save_ok  TYPE sy-ucomm.

*----------------------------------------------------------------------*
START-OF-SELECTION.
  CALL SCREEN 0100.

*======================================================================*
*  SCREEN 0100 - "Enter Vendor Invoice" (FB60 lookalike)
*
*  Dynpro fields to paint in SE51:
*     GV_BUKRS   Company Code   (input)
*     GV_LIFNR   Vendor         (input)
*     GV_XBLNR   Reference      (input)
*     GV_WRBTR   Amount         (input)
*     GV_WAERS   Currency       (input)
*     GV_OK_CODE OK code        (hidden)
*
*  GUI status STATUS_0100 needs fcodes:
*     POST  (F8)   -> post the invoice (will trigger AUTHORITY-CHECK)
*     CANC  (F12)  -> leave program
*
*  Flow logic (paste in SE51 "Flow logic" tab):
*     PROCESS BEFORE OUTPUT.
*       MODULE status_0100.
*     PROCESS AFTER INPUT.
*       MODULE user_command_0100.
*======================================================================*
MODULE status_0100 OUTPUT.
  SET PF-STATUS 'STATUS_0100'.
  SET TITLEBAR  'TITLE_0100'.
ENDMODULE.

MODULE user_command_0100 INPUT.
  gv_save_ok = gv_ok_code.
  CLEAR gv_ok_code.

  CASE gv_save_ok.
    WHEN 'CANC' OR 'BACK' OR 'EXIT'.
      LEAVE PROGRAM.

    WHEN 'POST'.
      " This is where a real FB60 would hit the auth object.
      AUTHORITY-CHECK OBJECT 'F_BKPF_BUK'
        ID 'BUKRS' FIELD gv_bukrs
        ID 'ACTVT' FIELD '01'.

      IF sy-subrc = 0.
        MESSAGE |Invoice { gv_xblnr } posted in BUKRS { gv_bukrs }| TYPE 'S'.
        LEAVE PROGRAM.
      ENDIF.

      " Auth failed -> pivot to SailPoint flow.
      gv_errtxt = |No authorization for company code { gv_bukrs } | &&
                  |(auth object F_BKPF_BUK, activity 01).|.
      LEAVE TO SCREEN 0200.
  ENDCASE.
ENDMODULE.

*======================================================================*
*  SCREEN 0200 - "Access denied - request via SailPoint?"
*
*  Dynpro fields:
*     GV_ERRTXT  Error message (output only, multi-line text)
*     GV_BUKRS   Company code  (output only)
*     GV_OK_CODE OK code       (hidden)
*
*  GUI status STATUS_0200 fcodes:
*     REQ   (Enter)  -> submit SailPoint request
*     CAN   (F12)    -> cancel / leave program
*
*  Flow logic:
*     PROCESS BEFORE OUTPUT.
*       MODULE status_0200.
*     PROCESS AFTER INPUT.
*       MODULE user_command_0200.
*======================================================================*
MODULE status_0200 OUTPUT.
  SET PF-STATUS 'STATUS_0200'.
  SET TITLEBAR  'TITLE_0200'.
ENDMODULE.

MODULE user_command_0200 INPUT.
  gv_save_ok = gv_ok_code.
  CLEAR gv_ok_code.

  CASE gv_save_ok.
    WHEN 'CAN' OR 'BACK' OR 'EXIT'.
      LEAVE PROGRAM.

    WHEN 'REQ'.
      PERFORM get_oauth_token  CHANGING gv_token.
      IF gv_token IS INITIAL.
        MESSAGE 'OAuth to SailPoint failed - see SM21/ST22' TYPE 'E'.
      ENDIF.

      PERFORM submit_request   USING    gv_token
                               CHANGING gv_reqid gv_http.
      LEAVE TO SCREEN 0300.
  ENDCASE.
ENDMODULE.

*======================================================================*
*  SCREEN 0300 - "Access request submitted"
*
*  Dynpro fields:
*     GV_HTTP    HTTP status (output)
*     GV_REQID   SailPoint request id (output)
*     GV_OK_CODE OK code (hidden)
*
*  GUI status STATUS_0300 fcodes:
*     BACK (F3) / EXIT (Shift+F3) -> leave program
*
*  Flow logic:
*     PROCESS BEFORE OUTPUT.
*       MODULE status_0300.
*     PROCESS AFTER INPUT.
*       MODULE user_command_0300.
*======================================================================*
MODULE status_0300 OUTPUT.
  SET PF-STATUS 'STATUS_0300'.
  SET TITLEBAR  'TITLE_0300'.
ENDMODULE.

MODULE user_command_0300 INPUT.
  gv_save_ok = gv_ok_code.
  CLEAR gv_ok_code.
  CASE gv_save_ok.
    WHEN OTHERS.
      LEAVE PROGRAM.
  ENDCASE.
ENDMODULE.

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
