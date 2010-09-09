# A RetainerDeliverable is an HourlyDeliverable that is renewed at
# regular calendar periods.  The Company bills a regular number of
# hours for a hourly rate whereby the budgets are reset over a
# regular cyclical period (monthly).
class RetainerDeliverable < HourlyDeliverable
  unloadable

  # Associations

  # Validations
  
  # Accessors

  # Callbacks
  before_update :check_for_extended_period
  before_update :check_for_shrunk_period
  
  def short_type
    'R'
  end

  def current_date
    Date.today
  end
  
  def current_period
    current_date.strftime("%B %Y")
  end

  def beginning_date
    start_date && start_date.beginning_of_month.to_date
  end

  def ending_date
    end_date && end_date.end_of_month.to_date
  end

  def date_range
    if beginning_date && ending_date && beginning_date <= ending_date
      (beginning_date..ending_date)
    else
      []
    end
  end

  def within_date_range?(date)
    date_range.include?(date)
  end

  def months
    month_acc = []

    current_date = beginning_date
    return [] if current_date.nil? || ending_date.nil?
    
    while current_date < ending_date do
      month_acc << current_date
      current_date = current_date.advance(:months => 1)
    end
    
    month_acc
  end

  # Returns the months used by the Deliverable that are before date
  def months_before_date(date)
    months.select {|m| m < date }
  end

  # Returns the months used by the Deliverable that are after date
  def months_after_date(date)
    months.select {|m| m > date }
  end

  def labor_budgets_for_date(date)
    budgets = labor_budgets.all(:conditions => {:year => date.year, :month => date.month})
    budgets = [labor_budgets.build(:year => date.year, :month => date.month)] if budgets.empty?
    budgets
  end

  def overhead_budgets_for_date(date)
    budgets = overhead_budgets.all(:conditions => {:year => date.year, :month => date.month})
    budgets = [overhead_budgets.build(:year => date.year, :month => date.month)] if budgets.empty?
    budgets
  end

  def labor_budget_total(date=nil)
    case scope_date_status(date)
    when :in
      labor_budgets.sum(:budget, :conditions => {:year => date.year, :month => date.month})
    when :out
      0
    else
      super
    end
  end

  def overhead_budget_total(date=nil)
    case scope_date_status(date)
    when :in
      overhead_budgets.sum(:budget, :conditions => {:year => date.year, :month => date.month})
    when :out
      0
    else
      super
    end
  end

  def labor_budget_hours(date=nil)
    case scope_date_status(date)
    when :in
      labor_budgets.sum(:hours, :conditions => {:year => date.year, :month => date.month})
    when :out
      0
    else
      super
    end
  end

  def total_spent(date=nil)
    if date
      if within_date_range?(date)
        # TODO: duplicated on HourlyDeliverable#total_spent
        return 0 if contract.nil?
        return 0 if contract.billable_rate.blank?
        return 0 unless self.issues.count > 0

        issue_ids = self.issues.collect(&:id)
        if issue_ids.present?
          time_logs = TimeEntry.all(:conditions => ["#{Issue.table_name}.id IN (:issue_ids) AND tyear = (:year) AND tmonth = (:month)",
                                                    {:issue_ids => issue_ids,
                                                      :year => date.year,
                                                      :month => date.month}
                                                   ],
                                    :include => :issue)
        end
        time_logs ||= []
        hours = time_logs.inject(0) {|total, time_entry|
          total += time_entry.hours if time_entry.billable?
          total
        }

        return hours * contract.billable_rate

      else
        0 # outside of range
      end
    else
      super
    end

  end

  # TODO: stolen directly from redmine_overhead but with a block option
  def labor_budget_spent_with_filter(&block)
    return 0.0 unless self.issues.size > 0
    total = 0.0
    
    # Get all timelogs assigned
    if block_given?
      time_logs = block.call
    else
      time_logs = self.issues.collect(&:time_entries).flatten
    end
    
    return time_logs.collect {|time_log|
      if time_log.billable?
        time_log.cost
      else
        0.0
      end
    }.sum
  end

  # TODO: stolen directly from redmine_overhead but with a block option
  def overhead_spent_with_filter(&block)
    if block_given?
      time_logs = block.call
    else
      time_logs = issues.collect(&:time_entries).flatten
    end

    return time_logs.collect {|time_entry|
      if time_entry.billable?
        0
      else
        time_entry.cost
      end
    }.sum 
  end

  def labor_budget_spent(date=nil)
    case scope_date_status(date)
    when :in
      labor_budget_spent_with_filter do
        issue_ids = self.issues.collect(&:id)
        time_entries_for_date_and_issue_ids(date, issue_ids)
      end
    when :out
      0
    else
      labor_budget_spent_with_filter
    end
  end

  def overhead_spent(date=nil)
    case scope_date_status(date)
    when :in
      overhead_spent_with_filter do
        issue_ids = self.issues.collect(&:id)
        time_entries_for_date_and_issue_ids(date, issue_ids)
      end
    when :out
      0
    else
      overhead_spent_with_filter
    end
  end

  def create_budgets_for_periods
    # For each month in the time span
    months.each do |month|
      # Iterate over all un-dated budgets, created dated versions
      undated_labor_budgets = labor_budgets.all(:conditions => ["#{LaborBudget.table_name}.year IS NULL AND #{LaborBudget.table_name}.month IS NULL"])
      undated_labor_budgets.each do |template_budget|
        labor_budgets.create(template_budget.attributes.merge(:year => month.year, :month => month.month))
      end

      undated_overhead_budgets = overhead_budgets.all(:conditions => ["#{OverheadBudget.table_name}.year IS NULL AND #{OverheadBudget.table_name}.month IS NULL"])
      undated_overhead_budgets.each do |template_budget|
        overhead_budgets.create(template_budget.attributes.merge(:year => month.year, :month => month.month))
      end
    end
    # Destroy origional un-dated budgets
    labor_budgets.all(:conditions => ["#{LaborBudget.table_name}.year IS NULL AND #{LaborBudget.table_name}.month IS NULL"]).collect(&:destroy)
    overhead_budgets.all(:conditions => ["#{OverheadBudget.table_name}.year IS NULL AND #{OverheadBudget.table_name}.month IS NULL"]).collect(&:destroy)
  end

  def check_for_extended_period
    # TODO: brute force. Alternative would be to check end_date_changes to see if the period actually shifted
    if end_date_changed?
      extend_period_to_new_end_date
    end

    # TODO: brute force. Alternative would be to check start_date_changes to see if the period actually shifted
    if start_date_changed?
      extend_period_to_new_start_date
    end
  end

  def check_for_shrunk_period
    if end_date_changed? || start_date_changed?
      shrink_budgets_to_new_period
    end
  end

  private

  def shrink_budgets_to_new_period
    return if beginning_date.nil? || ending_date.nil?
    labor_budgets.all.each do |labor_budget|
      # Purge un-dated budgets, should not be saved at all
      labor_budget.destroy unless labor_budget.year.present?
      labor_budget.destroy unless labor_budget.month.present?

      # Purge budgets outside the new beginning/ending range
      unless (beginning_date..ending_date).to_a.include?(Date.new(labor_budget.year, labor_budget.month, 1))
        labor_budget.destroy
      end
    end

    overhead_budgets.all.each do |overhead_budget|
      # Purge un-dated budgets, should not be saved at all
      overhead_budget.destroy unless overhead_budget.year.present?
      overhead_budget.destroy unless overhead_budget.month.present?

      # Purge budgets outside the new beginning/ending range
      unless (beginning_date..ending_date).to_a.include?(Date.new(overhead_budget.year, overhead_budget.month, 1))
        overhead_budget.destroy
      end
    end

    true
  end

  def extend_period_to_new_end_date
    return if end_date_change[0].nil? # No previous end date, so it will not have budgets

    old_end_date = end_date_change[0]
    last_labor_budgets = labor_budgets.all(:conditions => {:year => old_end_date.year, :month => old_end_date.month})
    last_overhead_budgets = overhead_budgets.all(:conditions => {:year => old_end_date.year, :month => old_end_date.month})

    months_after_date(old_end_date.end_of_month.to_date).each do |new_period|
      create_budgets_for_new_period(new_period, last_labor_budgets, last_overhead_budgets)
    end
  end

  def extend_period_to_new_start_date
    return if start_date_change[0].nil? # No previous start date, so it will not have budgets
    
    old_start_date = start_date_change[0]
    first_labor_budgets = labor_budgets.all(:conditions => {:year => old_start_date.year, :month => old_start_date.month})
    first_overhead_budgets = overhead_budgets.all(:conditions => {:year => old_start_date.year, :month => old_start_date.month})
    
    months_before_date(old_start_date.beginning_of_month.to_date).each do |new_period|
      create_budgets_for_new_period(new_period, first_labor_budgets, first_overhead_budgets)
    end

  end

  def create_budgets_for_new_period(new_period, labor_budgets_to_copy, overhead_budgets_to_copy)
    labor_budgets_to_copy.each do |labor_budget_to_copy|
      create_new_labor_budget_based_on_existing_budget(labor_budget_to_copy, 'year' => new_period.year, 'month' => new_period.month)
    end

    overhead_budgets_to_copy.each do |overhead_budget_to_copy|
      create_new_overhead_budget_based_on_existing_budget(overhead_budget_to_copy, 'year' => new_period.year, 'month' => new_period.month)
    end
  end
  
  def create_new_labor_budget_based_on_existing_budget(existing_labor_budget, attributes={})
    labor_budgets.create(existing_labor_budget.attributes.except('id').merge(attributes))
  end

  def create_new_overhead_budget_based_on_existing_budget(existing_overhead_budget, attributes={})
    overhead_budgets.create(existing_overhead_budget.attributes.except('id').merge(attributes))
  end

  def scope_date_status(date)
    if date
      if within_date_range?(date)
        status = :in
      else
        status = :out # outside of range
      end
    else
      status = :no_date
    end

    status
  end

  def time_entries_for_date_and_issue_ids(date, issue_ids)
    if issue_ids.present?
      TimeEntry.all(:conditions => ["#{Issue.table_name}.id IN (:issue_ids) AND tyear = (:year) AND tmonth = (:month)",
                                    {:issue_ids => issue_ids,
                                      :year => date.year,
                                      :month => date.month}
                                   ],
                    :include => :issue)
    else
      []
    end
  end
  
end
