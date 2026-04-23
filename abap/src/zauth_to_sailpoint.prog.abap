*&---------------------------------------------------------------------*
*& Report  ZAUTH_TO_SAILPOINT
*& Demo: lançamento de fatura com verificação de acesso em SailPoint.
*&
*& The program asks SailPoint ISC whether the declared user already
*& has the "Contas a Pagar / Accounts Payable" access profile. If yes,
*& the invoice is "posted". If not, the user is offered the chance to
*& submit a time-bound (30 day) access request with a justification.
*&
*& Only the OAuth client_id / client_secret are needed - the identity
*& id and access-profile id are resolved at runtime by name via
*& /v3/search, so no GUIDs have to be hand-copied from the tenant.
*&
*& ---------------------------------------------------------------
*& SSL prerequisites
*& ---------------------------------------------------------------
*& SailPoint tenants use TLS with a public CA. The SAP "SSL client
*& (Anonymous)" PSE must trust that chain. If the HTTP call fails
*& with ICM_HTTP_SSL_ERROR / SSL handshake error:
*&   1. Get chain: openssl s_client -showcerts -servername \
*&        company21824-poc.api.identitynow-demo.com \
*&        -connect company21824-poc.api.identitynow-demo.com:443 \
*&        </dev/null
*&      Save each "-----BEGIN CERTIFICATE-----" block to a .cer file.
*&   2. STRUST -> "SSL client SSL Client (Anonymous)" (double-click)
*&   3. Import Certificate -> pick each .cer -> Add to Certificate
*&      List. Save PSE.
*&   4. SMICM -> Administration -> ICM -> Reset (or restart).
*&
*& Technical keywords in EN, user-facing text in PT.
*&---------------------------------------------------------------------*
REPORT zauth_to_sailpoint.

*----------------------------------------------------------------------*
* Constants - only OAuth credentials and the AP name are needed.
* IDs are discovered at runtime.
*----------------------------------------------------------------------*
CONSTANTS:
  c_tenant_api TYPE string   VALUE 'https://company21824-poc.api.identitynow-demo.com',
  c_client_id  TYPE string   VALUE '43a4f8cd5fca43e1ac891ac9f5b9d711',
  c_client_sec TYPE string   VALUE '<<INJECT_AT_RUNTIME>>',
  c_ap_name    TYPE string   VALUE 'Contas a Pagar',
  c_tz_madrid  TYPE timezone VALUE 'CET'.

*----------------------------------------------------------------------*
* Selection screen - COMMENT + text symbols so PT labels always render
* (no DDIC fallback, no logon-language surprises).
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

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE TEXT-t02.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN COMMENT 1(25) TEXT-s06 FOR FIELD p_spuser.
    PARAMETERS p_spuser TYPE char50 DEFAULT 'maria.gonzalez' OBLIGATORY.
  SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b2.

*----------------------------------------------------------------------*
DATA: gv_token       TYPE string,
      gv_identity_id TYPE string,
      gv_id_display  TYPE string,
      gv_ap_id       TYPE string,
      gv_has_access  TYPE abap_bool,
      gv_reqid       TYPE string,
      gv_http        TYPE i,
      gv_err         TYPE string.

*----------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM get_oauth_token CHANGING gv_token gv_err.
  IF gv_token IS INITIAL.
    PERFORM inform_err USING 'Falha na autenticação OAuth.' gv_err.
    RETURN.
  ENDIF.

  PERFORM resolve_identity USING    gv_token p_spuser
                           CHANGING gv_identity_id
                                    gv_id_display
                                    gv_err.
  IF gv_identity_id IS INITIAL.
    PERFORM inform_err
      USING |Identidade SailPoint '{ p_spuser }' não encontrada.| gv_err.
    RETURN.
  ENDIF.

  PERFORM resolve_access_profile USING    gv_token c_ap_name
                                 CHANGING gv_ap_id gv_err.
  IF gv_ap_id IS INITIAL.
    PERFORM inform_err
      USING |Access profile '{ c_ap_name }' não encontrado.| gv_err.
    RETURN.
  ENDIF.

  PERFORM check_identity_has_access USING    gv_token
                                             gv_identity_id
                                             gv_ap_id
                                    CHANGING gv_has_access
                                             gv_err.

  IF gv_has_access = abap_true.
    MESSAGE |Fatura { p_xblnr } lançada na empresa { p_bukrs } | &&
            |(fornecedor { p_lifnr }, { p_wrbtr } { p_waers }).|
            TYPE 'S'.
    RETURN.
  ENDIF.

  PERFORM ask_and_submit_request USING gv_token gv_identity_id gv_ap_id.

*&---------------------------------------------------------------------*
*&  Popup: ask for justification + dates, then submit to SailPoint
*&---------------------------------------------------------------------*
FORM ask_and_submit_request USING iv_token       TYPE string
                                  iv_identity_id TYPE string
                                  iv_ap_id       TYPE string.

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

  " Default dates in Madrid timezone (CET / CEST with DST)
  GET TIME STAMP FIELD lv_ts.
  CONVERT TIME STAMP lv_ts TIME ZONE c_tz_madrid
    INTO DATE lv_today TIME lv_time.
  lv_end = lv_today + 30.

  CLEAR ls_field.
  ls_field-tabname   = 'BAPIRET2'.
  ls_field-fieldname = 'MESSAGE'.
  ls_field-fieldtext = 'Justificação'.
  ls_field-value     = |Lançamento FB60 - necessário acesso { c_ap_name } | &&
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
      popup_title     = |Pedido de acesso - { c_ap_name }|
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

  PERFORM submit_request USING    iv_token
                                  iv_identity_id
                                  iv_ap_id
                                  lv_comment
                                  lv_start_str
                                  lv_end_iso
                         CHANGING gv_reqid gv_http gv_err.

  IF gv_http = 200 OR gv_http = 201 OR gv_http = 202.
    lv_t1 = |Pedido aceite (HTTP { gv_http }).|.
    lv_t2 = |ID do pedido: { gv_reqid }|.
    lv_t3 = |Identidade: { gv_id_display }|.
    lv_t4 = |Válido até: { lv_end_iso }|.
  ELSEIF gv_http = 429.
    lv_t1 = 'Limite de pedidos excedido (HTTP 429).'.
    lv_t2 = 'Cabeçalho Retry-After indica o back-off.'.
    lv_t3 = 'Pode ter disparado workflow de anomalia.'.
    lv_t4 = ''.
  ELSEIF gv_http = 0.
    lv_t1 = 'Falha na comunicação HTTP.'.
    lv_t2 = gv_err.
    lv_t3 = 'Ver STRUST (SSL client Anonymous).'.
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
  lv_l3 = 'Ver STRUST, SM21 ou ST22 para detalhes.'.
  PERFORM inform USING 'SailPoint' lv_l1 lv_l2 lv_l3 ''.
ENDFORM.

*======================================================================*
*  HTTP helper - single place for send/receive + error capture
*======================================================================*
FORM http_exchange USING    iv_url      TYPE string
                            iv_method   TYPE string
                            iv_token    TYPE string    " '' = no auth header
                            iv_ctype    TYPE string
                            iv_body     TYPE string
                   CHANGING cv_code     TYPE i
                            cv_resp     TYPE string
                            cv_err      TYPE string.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_msg  TYPE string.

  CLEAR: cv_code, cv_resp, cv_err.

  cl_http_client=>create_by_url(
    EXPORTING  url                = iv_url
               ssl_id             = 'ANONYM'
    IMPORTING  client             = lo_http
    EXCEPTIONS argument_not_found = 1
               plugin_not_active  = 2
               internal_error     = 3
               OTHERS             = 4 ).
  IF sy-subrc <> 0.
    cv_err = |create_by_url failed sy-subrc={ sy-subrc }|.
    RETURN.
  ENDIF.

  lo_http->request->set_method( iv_method ).
  lo_http->request->set_header_field( name = 'Content-Type' value = iv_ctype ).
  IF iv_token IS NOT INITIAL.
    lo_http->request->set_header_field(
      name = 'Authorization' value = |Bearer { iv_token }| ).
  ENDIF.
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
FORM get_oauth_token CHANGING cv_token TYPE string
                              cv_err   TYPE string.
  DATA: lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  lv_url  = |{ c_tenant_api }/oauth/token|.
  lv_body = |grant_type=client_credentials|  &&
            |&client_id={ c_client_id }|     &&
            |&client_secret={ c_client_sec }|.

  PERFORM http_exchange USING    lv_url
                                 'POST'
                                 ''
                                 'application/x-www-form-urlencoded'
                                 lv_body
                        CHANGING lv_code lv_resp cv_err.

  IF lv_code <> 200.
    IF cv_err IS INITIAL.
      cv_err = |HTTP { lv_code }: { lv_resp }|.
    ENDIF.
    CLEAR cv_token.
    RETURN.
  ENDIF.

  " Crude JSON parse. In real Z code use /UI2/CL_JSON.
  FIND REGEX '"access_token"\s*:\s*"([^"]+)"'
       IN lv_resp SUBMATCHES cv_token.
ENDFORM.

*----------------------------------------------------------------------*
*  POST /v3/search indices=identities query="name:X OR alias:X OR email:X"
*  Returns first match id + displayName.
*----------------------------------------------------------------------*
FORM resolve_identity USING    iv_token     TYPE string
                               iv_user      TYPE string
                      CHANGING cv_id        TYPE string
                               cv_display   TYPE string
                               cv_err       TYPE string.
  DATA: lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i,
        lv_q    TYPE string.

  lv_url = |{ c_tenant_api }/v3/search|.
  lv_q   = |name:"{ iv_user }" OR alias:"{ iv_user }" OR email:"{ iv_user }"|.
  lv_body =
    |\{| &&
      |"indices":["identities"],| &&
      |"query":\{"query":"{ lv_q }"\},| &&
      |"sort":["-_score"]| &&
    |\}|.

  PERFORM http_exchange USING    lv_url 'POST' iv_token
                                 'application/json' lv_body
                        CHANGING lv_code lv_resp cv_err.

  IF lv_code <> 200.
    IF cv_err IS INITIAL.
      cv_err = |HTTP { lv_code }: { lv_resp }|.
    ENDIF.
    CLEAR cv_id.
    RETURN.
  ENDIF.

  FIND REGEX '"id"\s*:\s*"([^"]+)"'          IN lv_resp SUBMATCHES cv_id.
  FIND REGEX '"displayName"\s*:\s*"([^"]*)"' IN lv_resp SUBMATCHES cv_display.
ENDFORM.

*----------------------------------------------------------------------*
*  POST /v3/search indices=accessprofiles query="name.exact:X"
*----------------------------------------------------------------------*
FORM resolve_access_profile USING    iv_token   TYPE string
                                     iv_ap_name TYPE string
                            CHANGING cv_ap_id   TYPE string
                                     cv_err     TYPE string.
  DATA: lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  lv_url = |{ c_tenant_api }/v3/search|.
  lv_body =
    |\{| &&
      |"indices":["accessprofiles"],| &&
      |"query":\{"query":"name.exact:\\"{ iv_ap_name }\\""\}| &&
    |\}|.

  PERFORM http_exchange USING    lv_url 'POST' iv_token
                                 'application/json' lv_body
                        CHANGING lv_code lv_resp cv_err.

  IF lv_code <> 200.
    IF cv_err IS INITIAL.
      cv_err = |HTTP { lv_code }: { lv_resp }|.
    ENDIF.
    CLEAR cv_ap_id.
    RETURN.
  ENDIF.

  FIND REGEX '"id"\s*:\s*"([^"]+)"' IN lv_resp SUBMATCHES cv_ap_id.
ENDFORM.

*----------------------------------------------------------------------*
*  Is the access profile already assigned to the identity?
*----------------------------------------------------------------------*
FORM check_identity_has_access USING    iv_token       TYPE string
                                        iv_identity_id TYPE string
                                        iv_ap_id       TYPE string
                               CHANGING cv_has_access  TYPE abap_bool
                                        cv_err         TYPE string.
  DATA: lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  CLEAR cv_has_access.
  lv_url = |{ c_tenant_api }/v3/search|.
  lv_body =
    |\{| &&
      |"indices":["identities"],| &&
      |"query":\{| &&
        |"query":"id:{ iv_identity_id } AND accessProfiles.id:{ iv_ap_id }"| &&
      |\}| &&
    |\}|.

  PERFORM http_exchange USING    lv_url 'POST' iv_token
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

*----------------------------------------------------------------------*
*  POST /v3/access-requests with justification + removeDate
*----------------------------------------------------------------------*
FORM submit_request USING    iv_token       TYPE string
                             iv_identity_id TYPE string
                             iv_ap_id       TYPE string
                             iv_comment     TYPE string
                             iv_start       TYPE string
                             iv_end_iso     TYPE string
                    CHANGING cv_reqid       TYPE string
                             cv_http        TYPE i
                             cv_err         TYPE string.
  DATA: lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_cmt  TYPE string.

  lv_cmt = iv_comment.
  REPLACE ALL OCCURRENCES OF '\' IN lv_cmt WITH '\\'.
  REPLACE ALL OCCURRENCES OF '"' IN lv_cmt WITH '\"'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf   IN lv_cmt WITH ' '.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>newline IN lv_cmt WITH ' '.

  lv_url = |{ c_tenant_api }/v3/access-requests|.
  lv_body =
    |\{| &&
      |"requestedFor":["{ iv_identity_id }"],| &&
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

  PERFORM http_exchange USING    lv_url 'POST' iv_token
                                 'application/json' lv_body
                        CHANGING cv_http lv_resp cv_err.

  CLEAR cv_reqid.
  IF cv_http = 200 OR cv_http = 201 OR cv_http = 202.
    FIND REGEX '"id"\s*:\s*"([^"]+)"'
         IN lv_resp SUBMATCHES cv_reqid.
  ENDIF.
ENDFORM.
