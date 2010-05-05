require 'casclient'
require 'casclient/frameworks/rails/filter'

unless Setting.respond_to?(:cas_server_url)

  Redmine::Plugin.register :redmine_cas do
    name        "Redmine CAS plugin [disabled]"
    author      'Mirek'
    description "Redmine CAS authentication. To enable this plugin define 'cas_server_url' setting."
    version     '0.0.1'
  end

else

  Redmine::Plugin.register :redmine_cas do
    name        "Redmine CAS plugin"
    author      'Mirek Rusin <mirek [at] me [dot] com>'
    description "Redmine CAS authentication (#{Setting.cas_server_url})"
    version     '0.0.1'
    #menu        :account_menu, :cas_sign_in, { :controller => 'account', :action => 'cas_login' }, :caption => 'CAS sign in'
    
    settings :default => {
      'tab_text' => '',
      'tab_name' => 'Tab Name',
      'system_tab_text' => '',
      'system_tab_name' => 'System Tab Name',
      :cas => {
        :server           => '',
        :autocreate_users => false
      }
    }, :partial => 'settings/redminetab_settings'
    
  end
  
  CASClient::Frameworks::Rails::Filter.configure(
    :cas_base_url => Setting.cas_server_url
  )

  ActionController::Dispatcher.to_prepare do
  
    AccountController.class_eval do
    
      def login_with_cas
        if params[:username].blank? && params[:password].blank? && Setting.respond_to?(:cas_server_url)
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
        if Setting.respond_to?(:cas_server_url)
          logout_user
          CASClient::Frameworks::Rails::Filter.logout(self, home_url)
        else
          logout_without_cas
        end
      end
    
      alias_method_chain :logout, :cas
    
    end
  
  end

end
