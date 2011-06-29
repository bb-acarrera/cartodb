# coding: UTF-8

class ApplicationController < ActionController::Base
  protect_from_forgery
  helper :all

  before_filter :browser_is_html5_compliant?
  after_filter :remove_flash_cookie

  class NoHTML5Compliant < Exception; end;

  rescue_from NoHTML5Compliant, :with => :no_html5_compliant
  rescue_from RecordNotFound, :with => :render_404

  include SslRequirement

  unless Rails.env.production?
    def self.ssl_required(*splat)
      false
    end
    def self.ssl_allowed(*splat)
      true
    end
  end
  
  def access_token
    return nil unless logged_in?
    access_token = nil
    consumer = OAuth::Consumer.new(current_user.client_application.key, current_user.client_application.secret, :site => CartoDB.hostname)
    if !session[:access_token].blank? && !session[:access_token_secret].blank?
      access_token = OAuth::AccessToken.new(consumer, session[:access_token], session[:access_token_secret])
    end
    unless access_token
      request_token = consumer.get_request_token
      uri = URI.parse(request_token.authorize_url)
      http = Net::HTTP.new(uri.host, uri.port)
      if Rails.env.production?
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      request = Net::HTTP::Post.new(uri.request_uri, {'authorize' => '1', 'oauth_token' => request_token.token})
      request.set_form_data({'foo' => 'bar'}, ';') # Hack to avoid 401 LengthRequired
      res = http.request(request)
      url = URI.parse(res.header['location'])
      verifier = url.query.split('&').select{ |q| q =~ /^oauth_verifier/}.first.split('=')[1]
      access_token = request_token.get_access_token(:oauth_verifier => verifier)
      session[:access_token] = access_token.token
      session[:access_token_secret] = access_token.secret
    end
    access_token
  end

  protected
  
  def render_404
    respond_to do |format|
      format.html do
        render :file => "public/404.html.erb", :status => 404, :layout => false
      end
      format.json do
        render :nothing => true, :status => 404
      end
    end
  end
  
  def render_500
    respond_to do |format|
      format.html do
        render :file => "public/500.html", :status => 500, :layout => false
      end
    end
  end
  
  def login_required
    authenticated? || not_authorized
  end

  def api_authorization_required
    authenticate!(:api_authentication)
  end

  def not_authorized
    respond_to do |format|
      format.html do
        redirect_to login_path and return
      end
      format.json do
        render :nothing => true, :status => 401
      end
    end
  end

  def table_privacy_text(table)
    if table.is_a?(Table)
      table.private? ? 'PRIVATE' : 'PUBLIC'
    elsif table.is_a?(Hash)
      table["privacy"]
    end
  end
  helper_method :table_privacy_text

  def translate_error(exception)
    if exception.is_a?(String)
      return exception
    end
    case exception
      when CartoDB::EmptyFile
        ERROR_CODES[:empty_file]
      when Sequel::DatabaseError
        if exception.message.include?("transform: couldn't project")
          ERROR_CODES[:geometries_error].merge(:raw_error => exception.message)
        else
          ERROR_CODES[:unknown_error].merge(:raw_error => exception.message)
        end
      else
        ERROR_CODES[:unknown_error].merge(:raw_error => exception.message)
    end.to_json
  end

  def no_html5_compliant
    render :file => "#{Rails.root}/public/HTML5.html", :status => 500, :layout => false
  end

  def api_request?
    request.subdomain.eql?('api')
  end
  
  def browser_is_html5_compliant?
    return true if Rails.env.test? || api_request?
    user_agent = request.user_agent.try(:downcase)
    return true if user_agent.nil?
    
    #IE 6 
    # mozilla/4.0 (compatible; msie 8.0; windows nt 6.1; wow64; trident/4.0; slcc2; .net clr 2.0.50727; .net clr 3.5.30729; .net clr 3.0.30729; media center pc 6.0)
    if user_agent.match(/msie [0-6]/)
      raise NoHTML5Compliant
    end
    
    # login or developer ie ready
    if controller_name == "home" || controller_name == "invitations" || controller_name == "sessions" && !user_agent.match(/msie [0-6]/)
      return true
    end
    
    #IE 
    # mozilla/4.0 (compatible; msie 8.0; windows nt 6.1; wow64; trident/4.0; slcc2; .net clr 2.0.50727; .net clr 3.5.30729; .net clr 3.0.30729; media center pc 6.0)
    if user_agent.match(/msie [0-8]/)
      raise NoHTML5Compliant
    end
    
    #CHROME
    # mozilla/5.0 (macintosh; intel mac os x 10_6_7) applewebkit/534.30 (khtml, like gecko) chrome/12.0.742.91 safari/534.30
    if user_agent.match(/chrome\/\d[0-1]/)
      raise NoHTML5Compliant
    end
    
    #SAFARI
    # mozilla/5.0 (macintosh; u; intel mac os x 10_6_7; en-us) applewebkit/533.21.1 (khtml, like gecko) version/5.0.5 safari/533.21.1
    if user_agent.match(/safari\/[0-4][0-2][0-2]/) && !user_agent.match(/iphone/i) && !user_agent.match(/ipad/i) && !user_agent.match(/ipod/i) && !user_agent.match(/android/i)
      raise NoHTML5Compliant
    end
    
    #OPERA
    # opera/9.80 (macintosh; intel mac os x 10.6.7; u; mac app store edition; en) presto/2.8.131 version/11.11
    if user_agent.match(/opera\/[0-8].[0-7]/)
      raise NoHTML5Compliant
    end
    
    #MOZILLA
    # mozilla/5.0 (macintosh; intel mac os x 10.6; rv:2.0.1) gecko/20100101 firefox/4.0.1
    if user_agent.match(/firefox\/[0-2].[0-5]/)
      raise NoHTML5Compliant
    end
    
    #IPHONE IPAD IPOD
    # Mozilla/5.0 (iPhone; U; XXXXX like Mac OS X; en) AppleWebKit/420+ (KHTML, like Gecko) Version/3.0 Mobile/241 Safari/419.3
    # Checked in safari
    
    #ANDROID
    # Mozilla/5.0 (Linux; U; Android 0.5; en-us) AppleWebKit/522+ (KHTML, like Gecko) Safari/419.3
    # Checked in safari
  end
  
  # In some cases the flash message is going to be set in the fronted with js after making a request to the API
  # We use this filter to ensure it disappears in the very first request
  def remove_flash_cookie
    cookies.delete(:flash) if cookies[:flash]
  end
end
