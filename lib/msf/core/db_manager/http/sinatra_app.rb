require 'sinatra/base'
require 'msf/core/db_manager/http/servlet_helper'
require 'msf/core/db_manager/http/servlet/host_servlet'
require 'msf/core/db_manager/http/servlet/note_servlet'
require 'msf/core/db_manager/http/servlet/vuln_servlet'
require 'msf/core/db_manager/http/servlet/event_servlet'
require 'msf/core/db_manager/http/servlet/web_servlet'
require 'msf/core/db_manager/http/servlet/online_test_servlet'
require 'msf/core/db_manager/http/servlet/workspace_servlet'
require 'msf/core/db_manager/http/servlet/service_servlet'

class SinatraApp < Sinatra::Base

  helpers ServletHelper

  # Servlet registration
  register HostServlet
  register VulnServlet
  register EventServlet
  register WebServlet
  register OnlineTestServlet
  register NoteServlet
  register WorkspaceServlet
  register ServiceServlet

end