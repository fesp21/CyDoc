class InvoicesController < ApplicationController
  in_place_edit_for :invoice, :due_date

  print_action_for :insurance_recipe, :tray => :plain
  print_action_for :patient_letter, :tray => :invoice
  print_action_for :reminder, :tray => :invoice

  # POST /invoice/1/print
  def print
    @invoice = Invoice.find(params[:id])
    @treatment = @invoice.treatment
    @patient = @treatment.patient
    
    print_patient_letter
    print_insurance_recipe
    
    unless params[:print_copy]
      @invoice.state = 'printed'
      @invoice.save!
    end
    
    respond_to do |format|
      format.html { redirect_to invoices_path }
      format.js {
        render :update do |page|
          page.replace_html "sub-tab-content-invoices-#{@invoice.id}", :partial => 'show'
          page.replace "invoice_#{@invoice.id}_flash", :partial => 'printed_flash'
        end
      }
    end
  end
  
  # POST /invoices/print_all
  def print_all
    @invoices = Invoice.prepared
    
    for @invoice in @invoices
      print_patient_letter
      print_insurance_recipe
      
      @invoice.state = 'printed'
      @invoice.save!
    end

    respond_to do |format|
      format.html { redirect_to invoices_path }
      format.js { redirect_to invoices_path }
    end
  end

  def print_reminder_letter
    @invoice = Invoice.find(params[:id])
    @treatment = @invoice.treatment
    @patient = @treatment.patient
    
    print_reminder
    
    @invoice.state = 'reminded'
    @invoice.save!
    
    respond_to do |format|
      format.html { redirect_to invoices_path }
      format.js {
        render :update do |page|
          page.replace_html "sub-tab-content-invoices-#{@invoice.id}", :partial => 'show'
          page.replace "invoice_#{@invoice.id}_flash", :partial => 'reminded_flash'
        end
      }
    end
  end
  
  # GET /invoices/1/insurance_recipe
  def insurance_recipe
    @invoice ||= Invoice.find(params[:id])
    @patient = @invoice.patient

    respond_to do |format|
      format.html {}
      format.pdf { render_pdf }
    end
  end

  # GET /invoices/1/patient_letter
  def patient_letter
    @invoice ||= Invoice.find(params[:id])
    @patient = @invoice.patient

    respond_to do |format|
      format.html {}
      format.pdf { render_pdf }
    end
  end

  # GET /invoices/1/reminder
  def reminder
    @invoice ||= Invoice.find(params[:id])
    @patient = @invoice.patient

    respond_to do |format|
      format.html {}
      format.pdf { render_pdf }
    end
  end

  # GET /invoices
  def index
    query = params[:query]
    query ||= params[:search][:query] if params[:search]
    query ||= params[:quick_search][:query] if params[:quick_search]

    @invoices = Invoice.clever_find(query).paginate(:page => params['page'], :per_page => 20, :order => 'id DESC')
    
    respond_to do |format|
      format.html {
        render :action => 'list'
        return
      }
      format.js {
        render :update do |page|
          page.replace_html 'search_results', :partial => 'list'
        end
      }
    end
  end

  # GET /invoice/1
  def show
    @invoice = Invoice.find(params[:id])

    redirect_to :controller => :patients, :action => :show, :id => @invoice.patient.id, :tab => 'invoices', :sub_tab => "invoices_#{@invoice.id}"
  end

  # GET /invoices/new
  def new
    @invoice = Invoice.new
    @invoice.date = Date.today
    @patient = Patient.find(params[:patient_id])
    @treatment = Treatment.find(params[:treatment_id])
    
    respond_to do |format|
      format.html { }
      format.js {
        render :update do |page|
          page.replace_html "new_treatment_#{@treatment.id}_invoice", :partial => 'form'
          page['invoice_value_date'].select
        end
      }
    end
  end

  # POST /invoices
  def create
    @invoice = Invoice.new(params[:invoice])
    @patient = Patient.find(params[:patient_id])
    @treatment = Treatment.find(params[:treatment_id])
    
    # Tiers
    @tiers = Object.const_get(params[:tiers][:name]).new
    @tiers.patient = @patient
    @tiers.biller = Doctor.find(Thread.current["doctor_id"])
    @tiers.provider = Doctor.find(Thread.current["doctor_id"])

    @tiers.save
    @invoice.tiers = @tiers

    # Law
    @invoice.law = @treatment.law
    @invoice.treatment = @treatment
    @invoice.service_records = @treatment.sessions.collect{|s| s.service_records}.flatten

    # Saving
    if @invoice.save
      flash[:notice] = 'Erfolgreich erstellt.'

      respond_to do |format|
        format.html { redirect_to @invoice }
        format.js {
          render :update do |page|
            page.remove 'invoice_form'
            page.insert_html :bottom, 'sub-tab-content-invoices', :partial => 'shared/sub_tab_content', :locals => {:type => 'invoices', :tab => @invoice, :selected_tab => @invoice}
            page.insert_html :top, 'sub-tab-sidebar-invoices', :partial => 'shared/sub_tab_sidebar_item', :locals => {:type => 'invoices', :tab => @invoice, :selected_tab => @invoice}
            page.call 'showSubTab', "invoices-#{@invoice.id}", "invoices"
            page.replace "invoice_#{@invoice.id}_flash", :partial => 'created_flash'
          end
        }
      end
    else
      respond_to do |format|
        format.html { }
        format.js {
          render :update do |page|
            page.replace_html "new_treatment_#{@treatment.id}_invoice", :partial => 'form'
            page['invoice_value_date'].select
          end
        }
      end
    end
  end

  # POST /invcoice/1/book
  def book
    @invoice = Invoice.find(params[:id])
    @treatment = @invoice.treatment
    @patient = @treatment.patient
    
    booking = @invoice.build_booking
    
    if booking.save
      @invoice.state = 'booked'
      @invoice.save
    end
    
    respond_to do |format|
      format.html { }
      format.js {
        render :update do |page|
          page.replace_html "sub-tab-content-invoices-#{@invoice.id}", :partial => 'show'
          page.replace "invoice_#{@invoice.id}_flash", :partial => 'booked_flash'
        end
      }
    end
  end

  # DELETE /invoices/1
  def destroy
    @invoice = Invoice.find(params[:id])
    @treatment = @invoice.treatment
    
    # We destroy the invoice if it's just been prepared...
    if @invoice.state == "prepared"
      @invoice.destroy
      
      respond_to do |format|
        format.html { }
        format.js {
          render :update do |page|
            if params[:context] == "list"
              page.remove "invoice_#{@invoice.id}"
            else
              page.remove "sub-tab-invoices-#{@invoice.id}"
              page.remove "sub-tab-content-invoices-#{@invoice.id}"
              page.call 'showTab', "personal"
            end
          end
        }
      end
    # ... but do cancel it afterwards
    else
      @invoice.cancel
      @invoice.save!
      
      respond_to do |format|
        format.html { }
        format.js {
          render :update do |page|
            if params[:context] == "list"
              page.replace "invoice_#{@invoice.id}", :partial => 'item', :object => @invoice
            else
              page.replace "sub-tab-content-invoices-#{@invoice.id}", :partial => 'show'
            end
          end
        }
      end
    end
  end
end
