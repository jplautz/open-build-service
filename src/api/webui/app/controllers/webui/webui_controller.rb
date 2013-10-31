# Filters added to this controller will be run for all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

require 'frontend_compat'

module Webui
class WebuiController < ActionController::Base
  Rails.cache.set_domain if Rails.cache.respond_to?('set_domain');

  #before_filter :check_mobile_views
  before_filter :instantiate_controller_and_action_names
  before_filter :set_return_to, :reset_activexml, :authenticate
  before_filter :check_user
  before_filter :require_configuration
  after_filter :validate_xhtml
  after_filter :clean_cache

  # :notice and :alert are default, we add :success and :error
  add_flash_types :success, :error

  # FIXME: This belongs into the user controller my dear.
  # Also it would be better, but also more complicated, to just raise
  # HTTPPaymentRequired, UnauthorizedError or Forbidden
  # here so the exception handler catches it but what the heck...
  rescue_from ActiveXML::Transport::ForbiddenError do |exception|
    if exception.code == 'unregistered_ichain_user'
      render template: 'user/request_ichain' and return
    elsif exception.code == 'unregistered_user'
      render file: Rails.root.join('public/403'), formats: [:html], status: 402, layout: false and return
    elsif exception.code == 'unconfirmed_user'
      render file: Rails.root.join('public/402'), formats: [:html], status: 402, layout: false
    else
      if User.current.is_nobody?
        render file: Rails.root.join('public/401'), formats: [:html], status: :unauthorized, layout: false
      else
        render file: Rails.root.join('public/403'), formats: [:html], status: :forbidden, layout: false
      end
    end
  end
  
  class ValidationError < Exception
    attr_reader :xml, :errors

    def message
      errors
    end

    def initialize( _xml, _errors )
      @xml = _xml
      @errors = _errors
    end
  end

  class MissingParameterError < Exception; end
  rescue_from MissingParameterError do |exception|
    logger.debug "#{exception.class.name} #{exception.message} #{exception.backtrace.join('\n')}"
    render file: Rails.root.join('public/404'), status: 404, layout: false, formats: [:html]
  end

  protected

  def set_return_to
    if params['return_to_host']
      @return_to_host = params['return_to_host']
    else
      # we have a proxy in front of us
      @return_to_host = CONFIG['external_webui_protocol'] || 'http'
      @return_to_host += '://'
      @return_to_host += CONFIG['external_webui_host'] || request.host
    end
    @return_to_path = params['return_to_path'] || request.env['ORIGINAL_FULLPATH']
    logger.debug "Setting return_to: \"#{@return_to_path}\""
  end

  def require_login
    if User.current.is_nobody?
      render :text => 'Please login' and return false if request.xhr?
      flash[:error] = 'Please login to access the requested page.'
      mode = :off
      mode = CONFIG['proxy_auth_mode'] unless CONFIG['proxy_auth_mode'].blank?
      if (mode == :off)
        redirect_to :controller => :user, :action => :login, :return_to_host => @return_to_host, :return_to_path => @return_to_path
      else
        redirect_to :controller => :main, :return_to_host => @return_to_host, :return_to_path => @return_to_path
      end
      return false
    end
    return true
  end

  # sets session[:login] if the user is authenticated
  def authenticate
    mode = :off
    mode = CONFIG['proxy_auth_mode'] unless CONFIG['proxy_auth_mode'].blank?
    logger.debug "Authenticating with iChain mode: #{mode}"
    if mode == :on || mode == :simulate
      authenticate_proxy
    else
      authenticate_form_auth
    end
    if session[:login]
      logger.info "Authenticated request to \"#{@return_to_path}\" from #{session[:login]}"
    else
      logger.info "Anonymous request to #{@return_to_path}"
    end
  end

  def authenticate_proxy
    Rails.logger.debug 'PROXY!!!'
    mode = :off
    mode = CONFIG['proxy_auth_host'] unless CONFIG['proxy_auth_host'].blank?
    proxy_user = request.env['HTTP_X_USERNAME']
    proxy_user = CONFIG['proxy_test_user'] if mode == :simulate and CONFIG['proxy_test_user']
    proxy_email = request.env['HTTP_X_EMAIL']
    proxy_email = ICHAIN_TEST_EMAIL if mode == :simulate and ICHAIN_TEST_EMAIL
    if proxy_user
      session[:login] = proxy_user
      session[:email] = proxy_email
      # Set the headers for direct connection to the api, TODO: is this thread safe?
      ActiveXML::api.set_additional_header( 'X-Username', proxy_user )
      ActiveXML::api.set_additional_header( 'X-Email', proxy_email ) if proxy_email
    else
      session[:login] = nil
      session[:email] = nil
    end
  end

  def authenticate_form_auth
    if session[:login] and session[:password]
      # pass credentials to transport plugin, TODO: is this thread safe?
      ActiveXML::api.login session[:login], session[:password]
    end
  end

  def frontend
    FrontendCompat.new
  end

  def valid_file_name? name
    name =~ /^[-\w+~ ][-\w\.+~ ]*$/
  end

  def valid_role_name? name
    name =~ /^[\w\-\.+]+$/
  end

  def valid_target_name? name
    name =~ /^\w[-\.\w&]*$/
  end

  def valid_user_name? name
    name =~ /^[\w\-\.+]+$/
  end

  def valid_group_name? name
    name =~ /^[\w\-\.+]+$/
  end

  def reset_activexml
    transport = ActiveXML::api
    transport.delete_additional_header 'X-Username'
    transport.delete_additional_header 'X-Email'
    transport.delete_additional_header 'Authorization'
  end

  def required_parameters(*parameters)
    parameters.each do |parameter|
      unless params.include? parameter.to_s
        raise MissingParameterError.new "Required Parameter #{parameter} missing in #{request.url}"
      end
    end
  end

  def discard_cache?
    cc = request.headers['HTTP_CACHE_CONTROL']
    return false if cc.blank?
    return true if cc == 'max-age=0'
    return false unless cc == 'no-cache'
    return !request.xhr?
  end

  def find_hashed(classname, *args)
    ret = classname.find( *args )
    return Xmlhash::XMLHash.new({}) unless ret
    ret.to_hash
  end

  def instantiate_controller_and_action_names
    @current_action = action_name
    @current_controller = controller_name
  end

  def check_spiders
    @spider_bot = false
    if defined? TREAT_USER_LIKE_BOT or request.env.has_key? 'HTTP_OBS_SPIDER'
      @spider_bot = true
    end
  end
  private :check_spiders

  def lockout_spiders
    check_spiders
    if @spider_bot
       render :nothing => true
       return true
    end
    return false
  end

  def check_user
    check_spiders
    if session[:login]
      User.current = User.find_by_login session[:login]
    else
      # TODO: rebase on application_controller and use load_nobdy
      User.current = User.find_by_login('_nobody_')
    end
  end

  def map_to_workers(arch)
    case arch
    when 'i586' then 'x86_64'
    when 'ppc' then 'ppc64'
    when 's390' then 's390x'
    else arch
    end
  end
 
  private

  def put_body_to_tempfile(xmlbody)
    file = Tempfile.new('xml').path
    file = File.open(file + '.xml', 'w')
    file.write(xmlbody)
    file.close
    return file.path
  end
  private :put_body_to_tempfile

  def validate_xhtml
    return if request.xhr?
    return unless (response.status.to_i == 200 && response.content_type =~ /text\/html/i)
    return if Rails.env.production? or Rails.env.stage?

    errors = []
    xmlbody = String.new response.body
    xmlbody.gsub!(/[\n\r]/, "\n")
    xmlbody.gsub!(/&[^;]*sp;/, '')
    
    # now to something fancy - patch HTML5 to look like xhtml 1.1
    xmlbody.gsub!(%r{ data-\S+=\"[^\"]*\"}, ' ')
    xmlbody.gsub!(%r{ autocomplete=\"[^\"]*\"}, ' ')
    xmlbody.gsub!(%r{ placeholder=\"[^\"]*\"}, ' ')
    xmlbody.gsub!(%r{ required=\"[^\"]*\"}, ' ')
    xmlbody.gsub!(%r{ <tester .*}, ' ')
    xmlbody.gsub!('</tester>', ' ')
    xmlbody.gsub!(%r{ type=\"range\"}, ' type="text"')
    xmlbody.gsub!(%r{ min=\"[^\"]*\"}, ' ')
    xmlbody.gsub!(%r{ max=\"[^\"]*\"}, ' ')
    xmlbody.gsub!(%r{(<script src="[^\"]*\")>}, '\1 type="application/javascript">')
    xmlbody.gsub!('<script>', '<script type="application/javascript">')
    xmlbody.gsub!(%r{<mark>(.*)</mark>}, '<b>\1</b>')
    xmlbody.gsub!('<!DOCTYPE html>', '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">')
    xmlbody.gsub!('<html>', '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">')


    begin
      document = Nokogiri::XML::Document.parse(xmlbody, nil, nil, Nokogiri::XML::ParseOptions::STRICT)
    rescue Nokogiri::XML::SyntaxError => e
      errors << ('[%s:%s]' % [e.line, e.column]) + e.inspect
      errors << put_body_to_tempfile(xmlbody)
    end

    if document
      ses = XHTML_XSD.validate(document)
      unless ses.empty?
        document = nil
        errors << put_body_to_tempfile(xmlbody) 
        ses.each do |err|
          errors << ('[%s:%s]' % [err.line, err.column]) + err.inspect
        end
      end
    end

    unless document
      self.instance_variable_set(:@_response_body, nil)
      logger.debug "XML Errors #{errors.inspect} #{xmlbody}"
      render :template => 'webui/xml_errors', :locals => { :oldbody => xmlbody, :errors => errors }, :status => 400
    end
  end

  def require_configuration
    @configuration = ::Configuration.first
  end

  # Before filter to check if current user is administrator
  def require_admin
    unless User.current.is_admin?
      flash[:error] = 'Requires admin privileges'
      redirect_back_or_to :controller => 'main', :action => 'index' and return
    end
  end

  # After filter to clean up caches
  def clean_cache
  end

  def require_available_architectures
    @available_architectures = Architecture.where(available: 1)
  end

  def mobile_request?
    if params.has_key? :force_view
      # check if it's a reset
      if session[:force_view].to_s != 'mobile' && params[:force_view].to_s == 'mobile'
        session.delete :force_view 
      else
        session[:force_view] = params[:force_view]
      end
    end
    if session.has_key? :force_view
      if session[:force_view].to_s == 'mobile'
        request.env['mobile_device_type'] = :mobile
      else
        request.env['mobile_device_type'] = :forced_desktop
      end
    end
    unless request.env.has_key? 'mobile_device_type'
      if request.user_agent.nil? || request.env['HTTP_ACCEPT'].nil?
        request.env['mobile_device_type'] = :desktop
      else
        mobileesp = MobileESPConverted::UserAgentInfo.new(request.user_agent, request.env['HTTP_ACCEPT'])
        if mobileesp.is_tier_generic_mobile || mobileesp.is_tier_iphone || mobileesp.is_tier_rich_css || mobileesp.is_tier_tablet
          request.env['mobile_device_type'] = :mobile
        else
          request.env['mobile_device_type'] = :desktop
        end
      end
    end
    return request.env['mobile_device_type'] == :mobile
  end

  def check_mobile_views
    #prepend_view_path(Rails.root.join('app', 'mobile_views')) if mobile_request?
  end

  def check_ajax
    raise ActionController::RoutingError.new('Expected AJAX call') unless request.xhr?
  end
end
end