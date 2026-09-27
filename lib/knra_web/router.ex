defmodule KnraWeb.Router do
  use KnraWeb, :router

  import KnraWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KnraWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Other scopes may use custom stacks.
  # scope "/api", KnraWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:knra, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KnraWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authenticated staff routes
  #
  # Everything below requires a logged-in, active staff account. Role checks are
  # applied per LiveView with `on_mount {KnraWeb.LiveHooks, {:authorize, perm}}`
  # and again inside every context function.

  scope "/", KnraWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", PageController, :home
    get "/applications/:ref/invoice", DocumentController, :invoice
    get "/applications/:ref/certificate", DocumentController, :certificate
    get "/applications/:ref/photos/:file", DocumentController, :photo
    get "/admin/audit/export", DocumentController, :audit_export

    live_session :require_authenticated_user,
      on_mount: [{KnraWeb.UserAuth, :require_authenticated}, {KnraWeb.LiveHooks, :default}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/cas/lanes", LanesLive
      live "/cas/alarms", AlarmQueueLive
      live "/inspections", InspectionsLive
      live "/reports", ReportsLive
      live "/applications", ApplicationLive.Index
      live "/applications/:ref", ApplicationLive.Show

      live "/admin/devices", Admin.DevicesLive
      live "/admin/users", Admin.UsersLive, :index
      live "/admin/users/new", Admin.UsersLive, :new
      live "/admin/users/:id/edit", Admin.UsersLive, :edit
      live "/admin/fees", Admin.FeesLive, :index
      live "/admin/fees/new", Admin.FeesLive, :new
      live "/admin/payments", Admin.PaymentsLive
      live "/admin/audit", Admin.AuditLive
      live "/admin/integrations", Admin.IntegrationsLive

      live "/simulator", SimulatorLive
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  ## Public routes (login and certificate verification). There is no
  ## self-registration: supervisors create staff accounts.

  scope "/", KnraWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{KnraWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/verify", VerifyLive
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
