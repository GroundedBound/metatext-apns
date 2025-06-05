require 'sinatra'
require 'httparty'
require 'json'
require 'mail'

CK_ENVIRONMENT = ENV['CK_ENVIRONMENT'] || 'development' # development production
CK_API_TOKEN_DEVELOPMENT = ENV['CK_API_TOKEN_DEVELOPMENT']
CK_API_TOKEN_PRODUCTION = ENV['CK_API_TOKEN_PRODUCTION']
CK_ASSET_DOWNLOAD_SIZE_LIMIT = Integer(ENV['CK_ASSET_DOWNLOAD_SIZE_LIMIT']) rescue 30_000_000 # 30MB

MAIL_USERNAME_SENDER = ENV['MAIL_USERNAME_SENDER']
MAIL_USERNAME_RECEIVER = ENV['MAIL_USERNAME_RECEIVER']
MAIL_PASSWORD = ENV['MAIL_PASSWORD']

class CloudKitClient
    def initialize(environment = CK_ENVIRONMENT)
        @environment = environment
    end
    
    def lookup_records(record_names)
        unless record_names.is_a?(Array) && record_names.all? { |r| r.is_a?(String) } && !record_names.empty?
            raise ArgumentError, "record_names must be a non-empty array of strings"
        end
        
        api_token = @environment == 'production' ? CK_API_TOKEN_PRODUCTION : CK_API_TOKEN_DEVELOPMENT
        url = "https://api.apple-cloudkit.com/database/1/iCloud.com.jonny.live-photos/#{@environment}/public/records/lookup?ckAPIToken=#{api_token}"
        
        request_body = {
            zoneID: { zoneName: "_defaultZone" },
            records: record_names.map { |name| { recordName: name } }
        }
        HTTParty.post(url, headers: { 'Content-Type' => 'application/json' }, body: request_body.to_json)
    end
    
    def lookup_all_photo_records(photo_record_names)
        return [] if photo_record_names.nil? || photo_record_names.empty?
        
        response = lookup_records(photo_record_names)
        
        unless response.success?
            return response.code
        end
        
        begin
            data = JSON.parse(response.body)
            records = data["records"] || []
            records
            rescue JSON::ParserError
            500
        end
    end
    
    def fetch_photo_record_names(id)
        return nil unless id
        response = lookup_records([CGI.escape(id)])
        return nil unless response.success?
        
        begin
            json = JSON.parse(response.body)
            json["records"]&.first&.dig("fields", "photoRecordNames", "value")
            rescue JSON::ParserError => e
            nil
        end
    end
end

def parse_photo_record(record)
    fields = record["fields"]
    version = fields.dig("version", "value")
    mimes = fields.dig("MIMEs", "value")
    files = fields.dig("files", "value")
    
    thumbnail_mime = fields.dig("thumbnailMIME", "value")
    thumbnail = fields.dig("thumbnail", "value")
    
    if thumbnail_mime && thumbnail && !mimes.empty? && !files.empty?
        mimes[0] = thumbnail_mime
        files[0] = thumbnail
    end
    
    results = []
    
    files.each_with_index do |file, index|
        results << {
            MIME: mimes[index] || "",
            size: file["size"],
            downloadURL: file["downloadURL"],
            version: version
        }
    end
    
    results
end

def valid_parsed_photo_record?(arr)
    return false unless arr.is_a?(Array)
    return false unless arr.length == 1 || arr.length == 2
    
    return false unless arr.all? do |item|
        version = item[:version]
        mime = item[:MIME]
        size = item[:size]
        version == 1 &&
        mime.is_a?(String) && !mime.empty? &&
        size.is_a?(Numeric) && size <= CK_ASSET_DOWNLOAD_SIZE_LIMIT
    end
    
    first_is_image = arr[0][:MIME].start_with?("image/")
    return first_is_image if arr.length == 1
    
    first_is_image && arr[1][:MIME].start_with?("video/")
end

def show_live_photos(id, environment)
    client = CloudKitClient.new(environment || CK_ENVIRONMENT)
    photo_record_names = client.fetch_photo_record_names(id)
    records = client.lookup_all_photo_records(photo_record_names)
    
    return nil unless records.is_a?(Array)
    
    photo_records = records.map { |record| parse_photo_record(record) }
    valid_photo_records = photo_records&.select { |record| valid_parsed_photo_record?(record) }
    
    return nil if valid_photo_records.empty?
    
    structured_records = valid_photo_records.map do |record_arr|
        output = { photo: record_arr[0] }
        output[:video] = record_arr[1] if record_arr.length == 2
        output
    end
    
    structured_records.to_json
end

get '/live_photos/:id' do
    id = params[:id]
    return "Invalid URL" if id.nil? || id.empty?
    
    json_string = show_live_photos(id, params[:environment])
    app_url = "mona-livephotos://show?id=#{CGI.escape(id)}"
    
    if json_string
        erb :LivePhotoViewer, locals: {
            app_url: app_url,
            og_url: request.url,
            records_json: json_string,
            report_record_id: id
        }
    else
        erb :LivePhotos, locals: {
            app_url: app_url,
            og_url: request.url
        }
    end
end

get '/live_photos' do
    "Invalid URL"
end

get '/live_photos/' do
    "Invalid URL"
end

def send_mail(subject, body)
    Mail.defaults do
        delivery_method :smtp, {
            address: 'smtp.gmail.com',
            port: 587,
            user_name: MAIL_USERNAME_SENDER,
            password: MAIL_PASSWORD, # Not your main password—use App Passwords
            authentication: 'plain',
            enable_starttls_auto: true
        }
    end
    
    Mail.deliver do
        from     MAIL_USERNAME_SENDER
        to       MAIL_USERNAME_RECEIVER
        subject  subject
        body     body
    end
end

def reason_string(code)
    reasons = {
        "1" => "Copyright Infringement",
        "2" => "Privacy Violation",
        "3" => "Nudity or Sexual Content",
        "4" => "Violence or Graphic Content",
        "0" => "Other Reasons"
    }
    reasons[code.to_s] || code.to_s
end

post '/api/report_live_photos' do
    content_type :json
    
    begin
        # Parse JSON body
        request_payload = JSON.parse(request.body.read)
        
        record_id = request_payload['recordId']
        reason    = request_payload['reason']
        comment   = request_payload['comment']
        
        # Basic validation
        if record_id.nil? || reason.nil? || record_id.strip.empty? || reason.strip.empty?
            status 400
            return { error: "recordId and reason are required." }.to_json
        end
        
        reason_s = reason_string(reason)
        ck_url = "https://icloud.developer.apple.com/dashboard/database/teams/FF973S8UP2/containers/iCloud.com.jonny.live-photos/environments/PRODUCTION/records?using=queryRecords&database=public&zone=_defaultZone&recordType=PhotoCollection&filters%5B0%5D.fieldName=___recordID&filters%5B0%5D.type=EQUALS&filters%5B0%5D.fieldValue.type=referenceType&filters%5B0%5D.fieldValue.value=#{record_id}&recordName=#{record_id}"
        
        send_mail("Report a Concern: Live Photos", "#{reason_s}\n\nhttps://getmona.app/live_photos/#{record_id}\n\n#{ck_url}\n\n#{comment}")
        
        status 200
        { message: "Report received." }.to_json
        
    rescue JSON::ParserError
        status 400
        { error: "Invalid JSON." }.to_json
    end
end
