# frozen_string_literal: true

require 'apnotic'
require 'base64'
require 'sinatra'

require 'dotenv/load' if ENV['RACK_ENV'] == 'development'

CONNECTION_OPTIONS = {
  auth_method: :token,
  cert_path: StringIO.new(ENV['APNS_AUTH_KEY']),
  key_id: ENV['APNS_KEY_ID'],
  team_id: ENV['APPLE_TEAM_ID']
}.freeze

SANDBOX_CONNECTION = Apnotic::Connection.development(CONNECTION_OPTIONS.dup)

SANDBOX_CONNECTION.on(:error) { |e| puts "Connection error (sandbox): #{e}" }

CONNECTION_POOL =
  Apnotic::ConnectionPool.new(
    CONNECTION_OPTIONS.dup,
    size: ENV['CONNECTION_POOL_SIZE'].to_i
  ) do |connection|
    connection.on(:error) { |e| puts "Connection error: #{e}" }
  end

post '/push/:app_id/:device_token/:user_id' do
  request.body.rewind

  notification = Apnotic::Notification.new(params[:device_token])

  notification.topic = params[:app_id]
  notification.alert = { 'loc-key' => 'apns-default-message' }
  notification.mutable_content = true
  notification.interruption_level = "passive"

  if params[:fullenv] == 'true'
    notification.custom_payload = {
       i: params[:user_id],
       m: Base64.urlsafe_encode64(request.body.read),
       s: request.env['HTTP_ENCRYPTION'],
       k: request.env['HTTP_CRYPTO_KEY']
     }
  else
    notification.custom_payload = {
       i: params[:user_id],
       m: Base64.urlsafe_encode64(request.body.read),
       s: request.env['HTTP_ENCRYPTION'].split('salt=').last.split(';').first,
       k: request.env['HTTP_CRYPTO_KEY'].split('dh=').last.split(';').first
     }
  end

  if params[:sandbox] == 'true'
    push = SANDBOX_CONNECTION.prepare_push(notification)

    push.on(:response) { |r| puts "Bad response (sandbox): #{r.inspect}" unless r.ok? }

    SANDBOX_CONNECTION.push_async(push)
  else
    CONNECTION_POOL.with do |connection|
      push = connection.prepare_push(notification)

      push.on(:response) { |r| puts "Bad response: #{r.inspect}" unless r.ok? }

      connection.push_async(push)
    end
  end

  202
end


# Open in Mona
require 'uri'
require 'cgi'

get '/.well-known/apple-app-site-association' do
    send_file 'views/apple-app-site-association.json'
end

def add_param(url, param_name, param_value)
    uri = URI(url)
    params = URI.decode_www_form(uri.query || "") << [param_name, param_value]
    uri.query = URI.encode_www_form(params)
    uri.to_s
end

get '/open/:app_id' do
    app_id = params[:app_id]
    url_string = params[:url]
    
    if app_id.nil? || app_id.empty? || url_string.nil? || url_string.empty?
        400
    else
        param_url = add_param(url_string, "kjy", "spring")
        app_url = app_id + "://open?url=" + CGI.escape(url_string)
        
        erb :OpenInMona, { :locals => {
            :app_url => app_url,
            :website_url => param_url,
            :website_url_label => url_string
        }}
    end
end

get '/' do
    erb :DownloadMona, { :locals => {
        :auto_redirect => "true",
    }}
end

get '/home' do
    erb :DownloadMona, { :locals => {
        :auto_redirect => "false",
    }}
end

get '/live_photos/:id' do
    id = params[:id]
    
    if id.nil? || id.empty?
        400
    else
        app_url = "mona-livephotos://show?id=" + CGI.escape(id)
        
        erb :LivePhotos, { :locals => {
            :app_url => app_url,
            :og_url => request.url
        }}
    end
end

get '/redirect' do
    url = params[:url]
    
    if url.nil? || url.empty?
        400
    else
        title = params[:title]
        text = params[:text]
        
        if title.nil? || title.empty?
            title = "Redirect"
        end
        
        if text.nil? || text.empty?
            text = url
        end
        
        erb :Redirect, { :locals => {
            :og_url => request.url,
            :redirect_url => url,
            :title => title,
            :text => text
        }}
    end
end

get '/goldenegg/*' do
    subpath = params['splat'].first
    redirect "https://goldenegg-437a247aad0c.herokuapp.com/#{subpath}", 302
end
