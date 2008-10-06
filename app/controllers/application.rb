# Filters added to this controller apply to all controllers in the application.
# Likewise, all the methods added will be available for all controllers.

require 'digest/sha2'

class ApplicationController < ActionController::Base
  helper :all # include all helpers, all the time

  # See ActionController::RequestForgeryProtection for details
  # Uncomment the :secret if you're not using the cookie session store
  protect_from_forgery # :secret => '3fcb7aa9a24a90ec6fde37b3755a9ed7'

  # Authentication
  # ==============
  before_filter :authenticate

  private
  def authenticate
    authenticate_or_request_with_http_basic do |user_name, password|
      @current_doctor = Doctor.find_by_login_and_password(user_name, Digest::SHA256.hexdigest(password))
      if @current_doctor.nil?
        # Access not granted, return false
        false
      else
        @current_doctor_ids = @current_doctor.colleagues.map{|c| c.id}.uniq

        @printers = @current_doctor.office.printers if @current_doctor.office

        # TODO: Nice hack to add REGEXP support for SQLite, but application controller is bad place...
        if ActiveRecord::Base.connection.adapter_name.eql?("SQLite")
          db = ActiveRecord::Base.connection.instance_variable_get(:@connection)
          db.create_function("regexp", 2) do |func, expr, value|
            begin
              if value.to_s && value.to_s.match(Regexp.new(expr.to_s))
                func.set_result 1
              else
               func.set_result 0
              end
            rescue => e
              puts "error: #{e}"
            end
          end
        end

        # Return true as access is granted
        true
      end
    end
  end

  # PDF generation
  # ==============
  def render_to_pdf(options = nil)
    generator = IO.popen("html2ps.php", "w+")
    generator.puts render_to_string(options)
    generator.close_write

    data = generator.read
    generator.close
    
    return data
  end

  def render_pdf
    send_data(render_to_pdf(:template => "#{controller_name}/#{action_name}.html.erb", :layout => 'simple'))
  end
end

class Date
  # Date helpers
  def self.parse_europe(value)
    if value.is_a?(String)
      if value.match /.*-.*-.*/
        return Date.parse(value)
      end
      day, month, year = value.split('.').map {|s| s.to_i}
      month ||= Date.today.month
      year ||= Date.today.year
      year = expand_year(year, 2000)

      return Date.new(year, month, day)
    else
      return value
    end
  end

  def self.date_only_year?(value)
    value.is_a?(String) and value.strip.match /^\d{2,4}$/
  end

  def self.expand_year(value, base = 1900)
    year = value.to_i
    return year < 100 ? year + base : year
  end
end

module Print
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def print_action_for(method, options = {})
      define_method("print_#{method}") do
        self.send("#{method}")
        cups_host = options[:cups_host] || @printers[:cups_host]
        tray = options[:tray].to_sym || :plain
        device = options[:device] || @printers[:trays][tray]
        # You probably need the pdftops filter from xpdf, not poppler on the cups host
        # In my setup it generated an empty page otherwise
        logger.info("lp -h #{cups_host} -d #{device}")
        generator = IO.popen("lp -h #{cups_host} -d #{device}", "w+")
        generator.puts render_to_pdf(:template => "#{controller_name}/#{method}.html.erb", :layout => 'simple')
        generator.close_write

        # Just read to not create zombie processes... TODO: fix
        data = generator.read
        generator.close

        render :text => "<p>Gedruckt.</p>"
      end
    end
  end
end

ActionController::Base.send :include, Print

module ActiveRecord
  class Base
    def self.belongs_to_delegate(delegate_id, options = {})
      delegate_to(:belongs_to, delegate_id, options)
    end

    def self.has_one_delegate(delegate_id, options = {})
      delegate_to(:has_one, delegate_id, options)
    end

    private

    def self.delegate_to(macro, delegate_id, options = {})
      send macro, delegate_id, options

      save_callback = {:belongs_to => :before_save, :has_one => :after_save}[macro]

      send save_callback do |model|
        model.send(delegate_id).save
      end

      delegate_names = respond_to?('safe_delegate_names') ? safe_delegate_names : []
      delegate_names = (delegate_names - [delegate_id]) + [delegate_id]

      def_string, source_file, source_line = <<-"end_eval", __FILE__, __LINE__

        def self.safe_delegate_names
          #{delegate_names.inspect}
        end

        def safe_delegates
          self.class.safe_delegate_names.collect do |delegate_name|
            send(delegate_name).nil? ? send("build_\#{delegate_name}") : send(delegate_name)
          end
        end

        def method_missing(method_id, *args)
          safe_delegates.each do |delegate|
            return delegate.send(method_id, *args) if delegate.respond_to?(method_id)
          end
          super
        end

        def respond_to?(*args)
          safe_delegates.any? {|delegate| delegate.respond_to?(*args)} || super
        end

      end_eval

      module_eval def_string, source_file, source_line + 1
    end
  end
end
