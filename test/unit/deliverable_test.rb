require File.dirname(__FILE__) + '/../test_helper'

class DeliverableTest < ActiveSupport::TestCase
  should_belong_to :contract
  should_belong_to :manager
  should_have_many :labor_budgets
  should_have_many :overhead_budgets
  should_have_many :fixed_budgets
  should_have_many :issues

  should_validate_presence_of :title
  should_validate_presence_of :type
  should_validate_presence_of :manager

  should_allow_values_for :status, "", nil, 'open', 'locked', 'closed'
  should_not_allow_values_for :status, "other", "things", "1"

  should "default status to open" do
    assert_equal "open", Deliverable.new.status
  end

  context "#total=" do
    should "strip dollar signs when writing" do
      d = Deliverable.new
      d.total = '$100.00'
      
      assert_equal 100.00, d.total.to_f
    end

    should "strip commas when writing" do
      d = Deliverable.new
      d.total = '20,100.00'
      
      assert_equal 20100.00, d.total.to_f
    end

    should "strip spaces when writing" do
      d = Deliverable.new
      d.total = '20 100.00'
      
      assert_equal 20100.00, d.total.to_f
    end
  end

  context "with a locked contract" do
    should "block creating a new deliverable" do
      contract = Contract.generate!(:status => "locked")
      deliverable = FixedDeliverable.spawn(:contract => contract)

      assert !deliverable.valid?
      assert deliverable.errors.on_base.include?("Can't create a deliverable on a locked contract")
    end

    should "block deleting a deliverable" do
      contract = Contract.generate!
      deliverable = FixedDeliverable.generate!(:contract => contract).reload
      assert contract.lock!

      assert_no_difference("Deliverable.count") do
        deliverable.destroy
      end
      
    end
  end

  context "with a closed contract" do
    should "block creating a new deliverable" do
      contract = Contract.generate!(:status => "closed")
      deliverable = FixedDeliverable.spawn(:contract => contract)

      assert !deliverable.valid?
      assert deliverable.errors.on_base.include?("Can't create a deliverable on a closed contract")
    end

    should "block deleting a deliverable" do
      contract = Contract.generate!
      deliverable = FixedDeliverable.generate!(:contract => contract).reload
      assert contract.close!

      assert_no_difference("Deliverable.count") do
        deliverable.destroy
      end
      
    end
  end

  context "#billable_time_entry_activities" do
    setup do
      configure_overhead_plugin
      @project = Project.generate!(:identifier => 'main').reload
      @contract = Contract.generate!(:project => @project, :billable_rate => 10)
      @manager = User.generate!
      @deliverable = RetainerDeliverable.spawn(:contract => @contract, :manager => @manager, :title => "Retainer Title", :start_date => '2010-01-01', :end_date => '2010-03-31')

    end
    
    should "include all billable activities" do
      @billable_activity2 = TimeEntryActivity.generate!.reload
      @billable_activity2.custom_field_values = { @custom_field.id => 'true' }
      assert @billable_activity2.save

      assert @deliverable.billable_time_entry_activities.include?(@billable_activity), "Activity not included"
      assert @deliverable.billable_time_entry_activities.include?(@billable_activity2), "Activity not included"
      
    end
    
    should "not include nonbillable activities" do
      assert !@deliverable.billable_time_entry_activities.include?(@non_billable_activity3), "Non billable Activity included"
    end
    
  end

  context "#spent_for_activity" do
    should "return the total amount spent for an activity" do
      configure_overhead_plugin
      @project = Project.generate!(:identifier => 'main').reload
      @contract = Contract.generate!(:project => @project, :billable_rate => 10)
      @manager = User.generate!
      @deliverable = RetainerDeliverable.generate!(:contract => @contract, :manager => @manager, :title => "Retainer Title", :start_date => '2010-01-01', :end_date => '2010-03-31')
      create_issue_with_time_for_deliverable(@deliverable, {
                                               :activity => @billable_activity,
                                               :user => @manager,
                                               :hours => 5,
                                               :amount => 100
                                             })

      assert_equal 500.0, @deliverable.spent_for_activity(@billable_activity).to_f
    end
  end

  context "#budget_for_activity" do
    should "return the total amount budgeted for an activity" do
      configure_overhead_plugin
      @project = Project.generate!(:identifier => 'main').reload
      @contract = Contract.generate!(:project => @project, :billable_rate => 10)
      @manager = User.generate!
      @deliverable = RetainerDeliverable.generate!(:contract => @contract, :manager => @manager, :title => "Retainer Title", :start_date => '2010-01-01', :end_date => '2010-03-31')
      @deliverable.labor_budgets << LaborBudget.spawn(:budget => 100, :hours => 10, :time_entry_activity => @billable_activity)
      @deliverable.labor_budgets << LaborBudget.spawn(:budget => 100, :hours => 10, :time_entry_activity => @billable_activity)
      @deliverable.save!

      assert_equal 600.0, @deliverable.budget_for_activity(@billable_activity).to_f # 200 * 3 months (retainer)
    end
    
  end
  
  context "#hours_spent_for_activity" do
    should "return the total hours spent for an activity" do
      configure_overhead_plugin
      @project = Project.generate!(:identifier => 'main').reload
      @contract = Contract.generate!(:project => @project, :billable_rate => 10)
      @manager = User.generate!
      @deliverable = RetainerDeliverable.generate!(:contract => @contract, :manager => @manager, :title => "Retainer Title", :start_date => '2010-01-01', :end_date => '2010-03-31')
      create_issue_with_time_for_deliverable(@deliverable, {
                                               :activity => @billable_activity,
                                               :user => @manager,
                                               :hours => 5,
                                               :amount => 100
                                             })

      assert_equal 5.0, @deliverable.hours_spent_for_activity(@billable_activity).to_f

    end
    
  end

  context "#hours_budget_for_activity" do
    should "return the total hours budgeted for an activity" do
      configure_overhead_plugin
      @project = Project.generate!(:identifier => 'main').reload
      @contract = Contract.generate!(:project => @project, :billable_rate => 10)
      @manager = User.generate!
      @deliverable = RetainerDeliverable.generate!(:contract => @contract, :manager => @manager, :title => "Retainer Title", :start_date => '2010-01-01', :end_date => '2010-03-31')
      @deliverable.labor_budgets << LaborBudget.spawn(:budget => 100, :hours => 10, :time_entry_activity => @billable_activity)
      @deliverable.labor_budgets << LaborBudget.spawn(:budget => 100, :hours => 10, :time_entry_activity => @billable_activity)
      @deliverable.save!

      assert_equal 60.0, @deliverable.hours_budget_for_activity(@billable_activity).to_f # 20 * 3 months (retainer)
    end
    
  end

end
