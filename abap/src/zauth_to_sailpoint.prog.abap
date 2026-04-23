*&---------------------------------------------------------------------*
*& Report  ZAUTH_TO_SAILPOINT
*& Demo: lançamento de fatura com verificação de acesso em SailPoint.
*&
*& The program asks SailPoint ISC whether the declared user already
*& has the "Contas a Pagar / Accounts Payable" access profile. If yes,
*& the invoice is "posted". If not, the user is offered the chance to
*& submit a time-bound (30 day) access request with a justification.
*&
*& NO credentials, host or URL live in this source. Everything routes
*& through an SM59 HTTP destination + OA2C_CONFIG OAuth 2.0 client
*& profile, so rotation is a Basis action (not a code change).
*&
*& ---------------------------------------------------------------
*& One-time setup in SAP
*& ---------------------------------------------------------------
*&
*& 1. tx STRUST
*&    - "SSL client SSL Client (Anonymous)" PSE must trust the
*&      SailPoint tenant cert chain. Import intermediate + root .cer
*&      files, save, then SMICM -> Administration -> ICM -> reset.
*&
*& 2. tx OA2C_CONFIG (or SOAMANAGER -> OAuth 2.0 Client)
*&    - Create client profile: ZSAILPOINT_OAUTH
*&    - Grant type:            client_credentials
*&    - Client ID:              <from SailPoint API management>
*&    - Client Secret:          <from SailPoint API management>
*&    - Token endpoint URL:     https://<tenant>.api.identitynow-demo.com/oauth/token
*&    - Scope:                  (blank, unless tenant requires one)
*&
*& 3. tx SM59
*&    - Create connection type G (HTTP to External Server)
*&    - Destination name:       ZSAILPOINT              <-- c_rfc_dest
*&    - Target host:            <tenant>.api.identitynow-demo.com
*&    - Service No.:            443
*&    - Path Prefix:            /
*&    - Logon & Security tab:
*&         SSL:                 Active
*&         SSL Cert:            ANONYM (or your PSE)
*&         Authentication:      OAuth 2.0
*&         OAuth 2.0 Profile:   ZSAILPOINT_OAUTH
*&    - Connection Test must return HTTP 401 or similar; 200 only if
*&      the first call has already minted a token.
*&
*& Thereafter the ABAP kernel fetches, caches and refreshes the bearer
*& token automatically for every create_by_destination call. No
*& Authorization header is set manually anywhere in this report.
*&
*& Endpoints hit:
*&   /v3/search                identity-has-access check
*&   /v2026/access-profiles    GET full list (limit=250, sorted by
*&                             name); user picks one in a popup
*&   /v2026/access-requests    POST GRANT_ACCESS for the picked AP
*&
*& Identity: c_identity_id is the PAT owner GUID, resolved once via
*& /v3/search?indices=identities and pinned in code.
*&
*& Technical keywords in EN, user-facing text in PT. The access
*& profile to request is chosen at runtime from the popup list.
*&---------------------------------------------------------------------*
REPORT zauth_to_sailpoint.

*----------------------------------------------------------------------*
* Constants - only the SM59 dest name and AP name live in code.
*----------------------------------------------------------------------*
CONSTANTS:
  c_rfc_dest    TYPE rfcdest  VALUE 'ZSAILPOINT',
  c_tz_madrid   TYPE timezone VALUE 'CET',
  " PAT owner identity (Ariel.Bravo, ariel.bravo@gmail.com).
  " Resolved once via /v3/search and pinned here.
  c_identity_id TYPE string   VALUE '5d2c03e7f1e6423483733c21fe162fa0'.

TYPES: BEGIN OF ty_ap,
         id   TYPE c LENGTH 32,
         name TYPE c LENGTH 60,
       END OF ty_ap.

*----------------------------------------------------------------------*
* Selection screen - COMMENT + text symbols so PT labels always render
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-t01.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN COMMENT 1(25) TEXT-s01 FOR FIELD p_bukrs.
    PARAMETERS p_bukrs TYPE bukrs DEFAULT '1000' OBLIGATORY.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN COMMENT 1(25) TEXT-s02 FOR FIELD p_lifnr.
    PARAMETERS p_lifnr TYPE lifnr DEFAULT '0000100001' OBLIGATORY.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN COMMENT 1(25) TEXT-s03 FOR FIELD p_xblnr.
    PARAMETERS p_xblnr TYPE xblnr DEFAULT 'INV-2026-0423'.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN COMMENT 1(25) TEXT-s04 FOR FIELD p_wrbtr.
    PARAMETERS p_wrbtr TYPE wrbtr DEFAULT '1250.00'.
  SELECTION-SCREEN END OF LINE.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN COMMENT 1(25) TEXT-s05 FOR FIELD p_waers.
    PARAMETERS p_waers TYPE waers DEFAULT 'EUR'.
  SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b1.

*----------------------------------------------------------------------*
DATA: gv_ap_id      TYPE string,
      gv_ap_label   TYPE string,
      gv_has_access TYPE abap_bool,
      gv_reqid      TYPE string,
      gv_http       TYPE i,
      gv_err        TYPE string.

*----------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM list_and_pick_access_profile CHANGING gv_ap_id
                                                gv_ap_label
                                                gv_err.
  IF gv_ap_id IS INITIAL.
    " Empty id + non-empty err -> failure; otherwise the user just
    " cancelled the picker -> exit silently.
    IF gv_err IS NOT INITIAL.
      PERFORM inform_err USING 'Falha ao listar access profiles.' gv_err.
    ENDIF.
    RETURN.
  ENDIF.

  PERFORM check_identity_has_access USING    c_identity_id
                                             gv_ap_id
                                    CHANGING gv_has_access
                                             gv_err.

  IF gv_has_access = abap_true.
    MESSAGE |Fatura { p_xblnr } lançada na empresa { p_bukrs } | &&
            |(fornecedor { p_lifnr }, { p_wrbtr } { p_waers }, | &&
            |{ gv_ap_label }).|
            TYPE 'S'.
    RETURN.
  ENDIF.

  PERFORM ask_and_submit_request USING c_identity_id gv_ap_id gv_ap_label.

*&---------------------------------------------------------------------*
FORM ask_and_submit_request USING iv_identity_id TYPE string
                                  iv_ap_id       TYPE string
                                  iv_ap_label    TYPE string.

  DATA: lt_fields    TYPE TABLE OF sval,
        ls_field     TYPE sval,
        lv_rc        TYPE c LENGTH 1,
        lv_ts        TYPE timestamp,
        lv_today     TYPE d,
        lv_end       TYPE d,
        lv_time      TYPE t,
        lv_comment   TYPE string,
        lv_start_str TYPE string,
        lv_end_iso   TYPE string,
        lv_t1        TYPE string,
        lv_t2        TYPE string,
        lv_t3        TYPE string,
        lv_t4        TYPE string.

  GET TIME STAMP FIELD lv_ts.
  CONVERT TIME STAMP lv_ts TIME ZONE c_tz_madrid
    INTO DATE lv_today TIME lv_time.
  lv_end = lv_today + 30.

  CLEAR ls_field.
  ls_field-tabname   = 'BAPIRET2'.
  ls_field-fieldname = 'MESSAGE'.
  ls_field-fieldtext = 'Justificação'.
  ls_field-value     = |Lançamento FB60 - necessário acesso { iv_ap_label } | &&
                       |para empresa { p_bukrs }|.
  APPEND ls_field TO lt_fields.

  CLEAR ls_field.
  ls_field-tabname   = 'BKPF'.
  ls_field-fieldname = 'BUDAT'.
  ls_field-fieldtext = 'Data de início'.
  ls_field-value     = lv_today.
  APPEND ls_field TO lt_fields.

  CLEAR ls_field.
  ls_field-tabname   = 'BKPF'.
  ls_field-fieldname = 'VALUT'.
  ls_field-fieldtext = 'Data de fim'.
  ls_field-value     = lv_end.
  APPEND ls_field TO lt_fields.

  CALL FUNCTION 'POPUP_GET_VALUES'
    EXPORTING
      popup_title     = |Pedido de acesso - { iv_ap_label }|
      start_column    = 10
      start_row       = 5
    IMPORTING
      returncode      = lv_rc
    TABLES
      fields          = lt_fields
    EXCEPTIONS
      error_in_fields = 1
      OTHERS          = 2.

  IF sy-subrc <> 0 OR lv_rc = 'A'.
    RETURN.
  ENDIF.

  READ TABLE lt_fields INTO ls_field INDEX 1.
  lv_comment = ls_field-value.
  READ TABLE lt_fields INTO ls_field INDEX 2.
  lv_today   = ls_field-value.
  READ TABLE lt_fields INTO ls_field INDEX 3.
  lv_end     = ls_field-value.

  lv_start_str = |{ lv_today+0(4) }-{ lv_today+4(2) }-{ lv_today+6(2) }|.
  lv_end_iso   = |{ lv_end+0(4)   }-{ lv_end+4(2)   }-{ lv_end+6(2)   }T00:00:00.000Z|.

  PERFORM submit_request USING    iv_identity_id
                                  iv_ap_id
                                  lv_comment
                                  lv_start_str
                                  lv_end_iso
                         CHANGING gv_reqid gv_http gv_err.

  IF gv_http = 200 OR gv_http = 201 OR gv_http = 202.
    lv_t1 = |Pedido aceite (HTTP { gv_http }).|.
    lv_t2 = |ID do pedido: { gv_reqid }|.
    lv_t3 = |Identidade: { c_identity_id }|.
    lv_t4 = |Válido até: { lv_end_iso }|.
  ELSEIF gv_http = 429.
    lv_t1 = 'Limite de pedidos excedido (HTTP 429).'.
    lv_t2 = 'Cabeçalho Retry-After indica o back-off.'.
    lv_t3 = 'Pode ter disparado workflow de anomalia.'.
    lv_t4 = ''.
  ELSEIF gv_http = 0.
    lv_t1 = 'Falha na comunicação HTTP.'.
    lv_t2 = gv_err.
    lv_t3 = |Ver SM59 '{ c_rfc_dest }' e STRUST.|.
    lv_t4 = ''.
  ELSE.
    lv_t1 = |Pedido rejeitado (HTTP { gv_http }).|.
    lv_t2 = 'Ver SM21 / ST22 para resposta completa.'.
    lv_t3 = ''.
    lv_t4 = ''.
  ENDIF.

  PERFORM inform USING 'SailPoint' lv_t1 lv_t2 lv_t3 lv_t4.
ENDFORM.

*&---------------------------------------------------------------------*
FORM inform USING iv_title TYPE string
                  iv_l1    TYPE string
                  iv_l2    TYPE string
                  iv_l3    TYPE string
                  iv_l4    TYPE string.
  DATA: lv_title TYPE char50,
        lv_a     TYPE char70,
        lv_b     TYPE char70,
        lv_c     TYPE char70,
        lv_d     TYPE char70.
  lv_title = iv_title. lv_a = iv_l1. lv_b = iv_l2.
  lv_c     = iv_l3.    lv_d = iv_l4.
  CALL FUNCTION 'POPUP_TO_INFORM'
    EXPORTING titel = lv_title
              txt1  = lv_a
              txt2  = lv_b
              txt3  = lv_c
              txt4  = lv_d.
ENDFORM.

FORM inform_err USING iv_summary TYPE string
                      iv_detail  TYPE string.
  DATA: lv_l1 TYPE string,
        lv_l2 TYPE string,
        lv_l3 TYPE string.
  lv_l1 = iv_summary.
  lv_l2 = iv_detail.
  lv_l3 = |Ver SM59 '{ c_rfc_dest }', OA2C_CONFIG e STRUST.|.
  PERFORM inform USING 'SailPoint' lv_l1 lv_l2 lv_l3 ''.
ENDFORM.

*======================================================================*
*  HTTP helper - one place for destination, send/receive, error capture.
*  Authorization header is set by the kernel via OA2C profile, not here.
*======================================================================*
FORM http_exchange USING    iv_path   TYPE string
                            iv_method TYPE string
                            iv_ctype  TYPE string
                            iv_body   TYPE string
                   CHANGING cv_code   TYPE i
                            cv_resp   TYPE string
                            cv_err    TYPE string.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_msg  TYPE string.

  CLEAR: cv_code, cv_resp, cv_err.

  cl_http_client=>create_by_destination(
    EXPORTING  destination              = c_rfc_dest
    IMPORTING  client                   = lo_http
    EXCEPTIONS argument_not_found       = 1
               destination_not_found    = 2
               destination_no_authority = 3
               plugin_not_active        = 4
               internal_error           = 5
               OTHERS                   = 6 ).
  IF sy-subrc <> 0.
    cv_err = |create_by_destination '{ c_rfc_dest }' failed sy-subrc={ sy-subrc }|.
    RETURN.
  ENDIF.

  cl_http_utility=>set_request_uri(
    request = lo_http->request
    uri     = iv_path ).

  lo_http->request->set_method( iv_method ).
  lo_http->request->set_header_field( name = 'Content-Type' value = iv_ctype ).
  IF iv_body IS NOT INITIAL.
    lo_http->request->set_cdata( iv_body ).
  ENDIF.

  lo_http->send( EXCEPTIONS http_communication_failure = 1
                            http_invalid_state         = 2
                            http_processing_failed     = 3
                            http_invalid_timeout       = 4
                            OTHERS                     = 5 ).
  IF sy-subrc <> 0.
    lo_http->get_last_error( IMPORTING message = lv_msg ).
    cv_err = |send failed ({ sy-subrc }): { lv_msg }|.
    RETURN.
  ENDIF.

  lo_http->receive( EXCEPTIONS http_communication_failure = 1
                                http_invalid_state         = 2
                                http_processing_failed     = 3
                                OTHERS                     = 4 ).
  IF sy-subrc <> 0.
    lo_http->get_last_error( IMPORTING message = lv_msg ).
    cv_err = |receive failed ({ sy-subrc }): { lv_msg }|.
    RETURN.
  ENDIF.

  lo_http->response->get_status( IMPORTING code = cv_code ).
  cv_resp = lo_http->response->get_cdata( ).
ENDFORM.

*======================================================================*
*  SailPoint ISC helpers
*======================================================================*
FORM list_and_pick_access_profile
  CHANGING cv_ap_id    TYPE string
           cv_ap_label TYPE string
           cv_err      TYPE string.

  DATA: lv_resp   TYPE string,
        lv_code   TYPE i,
        lt_aps    TYPE STANDARD TABLE OF ty_ap,
        ls_ap     TYPE ty_ap,
        lv_choice TYPE i.

  CLEAR: cv_ap_id, cv_ap_label.

  PERFORM http_exchange USING    '/v2026/access-profiles?limit=250&sorters=name'
                                 'GET' 'application/json' ''
                        CHANGING lv_code lv_resp cv_err.
  IF lv_code <> 200.
    IF cv_err IS INITIAL.
      cv_err = |HTTP { lv_code }: { lv_resp }|.
    ENDIF.
    RETURN.
  ENDIF.

  TRY.
      /ui2/cl_json=>deserialize(
        EXPORTING json        = lv_resp
                  pretty_name = /ui2/cl_json=>pretty_mode-camel_case
        CHANGING  data        = lt_aps ).
    CATCH cx_root INTO DATA(lx).
      cv_err = |JSON parse failed: { lx->get_text( ) }|.
      RETURN.
  ENDTRY.

  IF lt_aps IS INITIAL.
    cv_err = 'Lista de access profiles vazia.'.
    RETURN.
  ENDIF.

  CALL FUNCTION 'POPUP_WITH_TABLE_DISPLAY'
    EXPORTING
      endpos_col   = 100
      endpos_row   = 25
      startpos_col = 5
      startpos_row = 5
      titletext    = 'Selecione access profile'
    IMPORTING
      choise       = lv_choice
    TABLES
      valuetab     = lt_aps
    EXCEPTIONS
      break_off    = 1
      OTHERS       = 2.

  IF sy-subrc <> 0 OR lv_choice IS INITIAL.
    " Cancelled - leave cv_ap_id empty, no error.
    RETURN.
  ENDIF.

  READ TABLE lt_aps INTO ls_ap INDEX lv_choice.
  cv_ap_id    = ls_ap-id.
  cv_ap_label = ls_ap-name.
ENDFORM.

FORM check_identity_has_access USING    iv_identity_id TYPE string
                                        iv_ap_id       TYPE string
                               CHANGING cv_has_access  TYPE abap_bool
                                        cv_err         TYPE string.
  DATA: lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  CLEAR cv_has_access.
  lv_body =
    |\{| &&
      |"indices":["identities"],| &&
      |"query":\{| &&
        |"query":"id:{ iv_identity_id } AND accessProfiles.id:{ iv_ap_id }"| &&
      |\}| &&
    |\}|.

  PERFORM http_exchange USING    '/v3/search' 'POST'
                                 'application/json' lv_body
                        CHANGING lv_code lv_resp cv_err.

  IF lv_code <> 200.
    IF cv_err IS INITIAL.
      cv_err = |HTTP { lv_code }: { lv_resp }|.
    ENDIF.
    RETURN.
  ENDIF.

  IF lv_resp CS |"id":"{ iv_identity_id }"|.
    cv_has_access = abap_true.
  ENDIF.
ENDFORM.

FORM submit_request USING    iv_identity_id TYPE string
                             iv_ap_id       TYPE string
                             iv_comment     TYPE string
                             iv_start       TYPE string
                             iv_end_iso     TYPE string
                    CHANGING cv_reqid       TYPE string
                             cv_http        TYPE i
                             cv_err         TYPE string.
  DATA: lv_body TYPE string,
        lv_resp TYPE string,
        lv_cmt  TYPE string.

  lv_cmt = iv_comment.
  REPLACE ALL OCCURRENCES OF '\' IN lv_cmt WITH '\\'.
  REPLACE ALL OCCURRENCES OF '"' IN lv_cmt WITH '\"'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf   IN lv_cmt WITH ' '.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>newline IN lv_cmt WITH ' '.

  lv_body =
    |\{| &&
      |"requestedFor":"{ iv_identity_id }",| &&
      |"requestType":"GRANT_ACCESS",| &&
      |"requestedItems":[\{| &&
        |"type":"ACCESS_PROFILE",| &&
        |"id":"{ iv_ap_id }",| &&
        |"comment":"{ lv_cmt }",| &&
        |"removeDate":"{ iv_end_iso }",| &&
        |"clientMetadata":\{| &&
          |"sourceSystem":"SAP-PRD",| &&
          |"tcode":"FB60",| &&
          |"accessStartDate":"{ iv_start }",| &&
          |"bukrs":"{ p_bukrs }",| &&
          |"lifnr":"{ p_lifnr }",| &&
          |"xblnr":"{ p_xblnr }",| &&
          |"triggeredBy":"ZAUTH_TO_SAILPOINT"| &&
        |\}| &&
      |\}]| &&
    |\}|.

  PERFORM http_exchange USING    '/v2026/access-requests' 'POST'
                                 'application/json' lv_body
                        CHANGING cv_http lv_resp cv_err.

  CLEAR cv_reqid.
  IF cv_http = 200 OR cv_http = 201 OR cv_http = 202.
    FIND REGEX '"id"\s*:\s*"([^"]+)"'
         IN lv_resp SUBMATCHES cv_reqid.
  ENDIF.
ENDFORM.
