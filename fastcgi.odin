package fastcgi

import t "./types"
import platform "./platform"

run :: platform.run

Request :: t.Request
Header :: t.Http_Header
Response :: t.Response
On_Request :: t.On_Request
