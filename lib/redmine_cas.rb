require 'httpclient'
require 'casclient'
require 'casclient/frameworks/rails/filter'

Redmine::Plugin.register :redmine_cas do
  name        "Redmine CAS plugin"
  author      'Mirek Rusin'
  description "Redmine CAS authentication"
  version     '0.0.2'
  
  menu        :account_menu,
              :login_without_cas,
              {
                :controller => 'account',
                :action     => 'login_without_cas'
              },
              :caption => 'Sign in without CAS',
              :after   => :login
  
  settings :default => {
    :enabled      => false,
    :cas_base_url => 'https://localhost'
  }, :partial => 'settings/settings'
  
end

class RedmineCas
  
  class << self
    
    def client_config
      CASClient::Frameworks::Rails::Filter.config
    end
  
    def plugin
      Redmine::Plugin.find(:redmine_cas)
    end
    
    # Get plugin setting value or it's default value in a safe way.
    # If the setting key is not found, returns nil.
    def get_setting(name)
      if Setting["plugin_#{plugin.id}"]
        Setting["plugin_#{plugin.id}"][name]
      else
        if plugin.settings[:default].has_key?(name)
          plugin.settings[:default][name]
        end
      end
    end
  
    # Update CAS configuration using settings.
    # Has to be run at least once and can be run more times (after plugin configuration updates).
    def configure_client!
      CASClient::Frameworks::Rails::Filter.configure(
        :cas_base_url => RedmineCas.get_setting(:cas_base_url)
      )
    end
    
    # Check if CAS client has the same config as plugin
    def client_config_up_to_date?
      client_config && client_config[:cas_base_url] == plugin.settings['cas_base_url']
    end
    
    # Is CAS enabled, client configured and server available
    def ready?
      get_setting(:enabled) && server_reachable_by_client?
    end
    
    # Check if server at configured url is alive
    def server_reachable_by_client?
      begin
        if url = client_config[:cas_base_url]
          if @server_available_for_url[url]
            true
          else
            if !HTTPClient.new.get_content(url).empty?
              @server_available_for_url[url] = true
            else
              false
            end
          end
        else
          false
        end
#      rescue
#        false
      end
    end
    
  end
  
end

# Let's use dispatcher to setup CAS.
# This way we can use it in development (executed on every reload) and production (executed on first reload only)
# without worrying about plugins not being reloaded.
ActionController::Dispatcher.to_prepare do

  unless RedmineCas.client_config_up_to_date?
    RedmineCas.configure_client!
  end
  
  AccountController.class_eval do
  
    def login_with_cas
      if params[:username].blank? && params[:password].blank? && RedmineCas.ready?
        if session[:user_id]
          true
        else
          if CASClient::Frameworks::Rails::Filter.filter(self)
            if user = User.find_by_login(session[:cas_user])
              session[:user_id] = user.id
              user_setup
              redirect_to :controller => 'my', :action => 'page'
            else
              unless flash[:error]
                flash[:error] = l(:cas_authenticated_user_not_found, session[:cas_user])
                redirect_to :controller => params[:controller],
                            :action     => params[:action],
                            :back_url   => params[:back_url]
              end
            end
          end
        end
      else
        login_without_cas
      end
    end
    
    alias_method_chain :login, :cas
    
    def logout_with_cas
      if session[:cas_user]
        CASClient::Frameworks::Rails::Filter.logout(self, home_url)
        logout_user
      else
        logout_without_cas
      end
    end
  
    alias_method_chain :logout, :cas
  
  end

end
