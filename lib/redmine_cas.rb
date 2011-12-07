require 'casclient'
require 'casclient/frameworks/rails/filter'
require 'socket'
require 'timeout'

if defined?(Redmine)
  Redmine::Plugin.register :redmine_cas do
    name        "CAS Authentication"
    author      'Mirek Rusin'
    description "CAS single sign-on service authentication support. After configuring plugin login/logout actions will be delegated to CAS server."
    version     '0.0.3'
  
    menu        :account_menu,
                :login_without_cas,
                {
                  :controller => 'account',
                  :action     => 'login_without_cas'
                },
                :caption => :login_without_cas,
                :after   => :login,
                :if      => Proc.new { RedmineCas.ready? && RedmineCas.get_setting(:login_without_cas) && !User.current.logged? }
  
    settings :default => {
      :enabled                         => false,
      :cas_base_url                    => 'https://localhost',
      :login_without_cas               => false,
      :auto_create_users               => false,
      :auto_update_attributes_on_login => false,
      :cas_logout => true
    }, :partial => 'settings/settings'
  
  end
end

# Utility class to simplify plugin usage
class RedmineCas
  
  class << self
    
    def client_configured?
      if client_config
        !client_config[:cas_base_url].blank?
      end
    end
    
    def client_config
      CASClient::Frameworks::Rails::Filter.config
    end
  
    def plugin
      Redmine::Plugin.find(:redmine_cas)
    end
    
    # Get plugin setting value or it's default value in a safe way.
    # If the setting key is not found, returns nil.
    # If the plugin has not been registered yet, returns nil.
    def get_setting(name)
      begin
        if plugin
          if Setting["plugin_#{plugin.id}"]
            Setting["plugin_#{plugin.id}"][name]
          else
            if plugin.settings[:default].has_key?(name)
              plugin.settings[:default][name]
            end
          end
        end
      rescue
        
        # We don't care about exceptions which can actually occur ie. when running
        # migrations and settings table has not yet been created.
        nil
      end
    end
  
    # Update CAS configuration using settings.
    # Can be run more than once (it's invoked on each plugin settings update).
    def configure!
      # (Re)configure client if not configured or settings changed
      if !get_setting(:cas_base_url).blank? && (client_config[:cas_base_url] rescue nil) != get_setting(:cas_base_url)
        CASClient::Frameworks::Rails::Filter.configure(
          :cas_base_url => get_setting(:cas_base_url)
        )
      end
    end
    
    # Is CAS enabled, client configured and server available
    def ready?
      get_setting(:enabled) && client_configured? && url_has_open_port?(client_config[:cas_base_url])
    end
    
    # Check if a host at provided url is reachable and has an open port
    def url_has_open_port?(url, use_successful_results_cache = true)
      begin
        @successful_results_cache ||= {}
        if use_successful_results_cache && @successful_results_cache[url]
          
          # Successfully checked this host before
          true
        else
          
          # Let's parse the url first
          parsed_url = URI.parse(url)
          begin
            
            # Opening a socket can take too long, time out in magic 3 seconds
            Timeout::timeout(3) do
              begin
                puts "checking #{parsed_url.host} port #{parsed_url.port} #{parsed_url.to_yaml}"
                TCPSocket.new(parsed_url.host, parsed_url.port).close
                @successful_results_cache[url] = true
              rescue # Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEOUT
                
                # Host not found, port not opened or other error
                false
              end
            end
          rescue Timeout::Error
            
            # For us it's the same as host not reachable
            false
          end
        end
      rescue
        
        # Unknown error
        false
      end
    end
    
    # Return User model friendly attributes from CAS session.
    # Returned attributes can be used for User#update_attributes(...)
    # Please note :login attribute is not included.
    # Supported attribute names include :firstname, :lastname and :mail (from CAS :givenName, :sn and :mail attributes)
    def user_attributes_by_session(session)
      attributes = {}
      if extra_attributes = session[:cas_extra_attributes]
        attributes[:firstname] = extra_attributes[:givenName].first if extra_attributes[:givenName] && extra_attributes[:givenName].first
        attributes[:lastname] = extra_attributes[:sn].first if extra_attributes[:sn] && extra_attributes[:sn].first
        attributes[:mail] = extra_attributes[:mail].first if extra_attributes[:mail] &&  extra_attributes[:mail].first
      end
      attributes
    end
    
  end
  
end

# We're using dispatcher to setup CAS.
# This way we can work in development environment (where to_prepare is executed on every page reload)
# and production (executed once on first page load only).
# This way we're avoiding the problem where Rails reloads models but not plugins in development mode.
if defined?(ActionController)
  
  ActionController::Dispatcher.to_prepare do
  
    # We're watching for setting updates for the plugin.
    # After each change we want to reconfigure CAS client.
    Setting.class_eval do
      after_save do
        if name == 'plugin_redmine_cas'
          RedmineCas.configure!
        end
      end
    end
  
    # Let's (re)configure our plugin according to the current settings
    RedmineCas.configure!

    AccountController.class_eval do
  
      def login_with_cas
        if params[:username].blank? && params[:password].blank? && RedmineCas.ready?
          if session[:user_id]
            true
          else
            if CASClient::Frameworks::Rails::Filter.filter(self)
            
              # User has been successfully authenticated with CAS
              user = User.find_or_initialize_by_login(session[:cas_user])
              unless user.new_record?
              
                # ...and also found in Redmine
                if user.active?
                
                  # ...and user is active
                  if RedmineCas.get_setting(:auto_update_attributes_on_login)
                  
                    # Plugin configured to update users from CAS extra user attributes
                    unless user.update_attributes(RedmineCas.user_attributes_by_session(session))
                      # TODO: error updating attributes on login from CAS. We can skip this for now.
                    end
                  end
                  successful_authentication(user)
                else
                  account_pending
                end
              else
              
                # ...user has been authenticated with CAS but not found in Redmine
                if RedmineCas.get_setting(:auto_create_users)
                
                  # Plugin config says to create user, let's try by getting as much as possible
                  # from CAS extra user attributes. To add/remove extra attributes passed from CAS
                  # server, please refer to your CAS server documentation.
                  user.attributes = RedmineCas.user_attributes_by_session(session)
                  user.status = User::STATUS_REGISTERED

                  register_automatically(user) do
                    onthefly_creation_failed(user)
                  end
                else
                
                  # User auto-create disabled in plugin config
                  flash[:error] = l(:cas_authenticated_user_not_found, session[:cas_user])
                  redirect_to home_url
                end
              end
            else
            
              # Not authenticated with CAS, CASClient::Frameworks::Rails::Filter.filter(self) takes care of redirection
            end
          end
        else
          login_without_cas
        end
      end
    
      alias_method_chain :login, :cas
    
      def logout_with_cas
        if RedmineCas.ready? and RedmineCas.get_setting(:cas_logout)
          CASClient::Frameworks::Rails::Filter.logout(self, home_url)
          logout_user
        else
          logout_without_cas
        end
      end
  
      alias_method_chain :logout, :cas
  
    end

  end

end
