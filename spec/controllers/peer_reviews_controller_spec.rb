require 'set'

describe PeerReviewsController do
  TEMP_CSV_FILE_PATH = 'files/_temp_peer_review.csv'

  before :each do
    allow(controller).to receive(:session_expired?).and_return(false)
    allow(controller).to receive(:logged_in?).and_return(true)
    allow(controller).to receive(:current_user).and_return(build(:admin))

    @assignment_with_pr = create(:assignment_with_peer_review_and_groupings_results)
    @pr_id = @assignment_with_pr.pr_assignment.id
    @selected_reviewer_group_ids = @assignment_with_pr.pr_assignment.groupings.map(&:id)
    @selected_reviewee_group_ids = @assignment_with_pr.groupings.map(&:id)


  end

  context 'random assign' do
    before :each do
      post :assign_groups,
           params: { actionString: 'random_assign',
                     selectedReviewerGroupIds: @selected_reviewer_group_ids,
                     selectedRevieweeGroupIds: @selected_reviewee_group_ids,
                     assignment_id: @pr_id,
                     numGroupsToAssign: 1
           }
    end

    it 'creates the correct number of peer reviews' do
      expect(PeerReview.all.size).to eq 3
    end

    it 'does not assign a reviewee group to review their own submission' do
      PeerReview.all.each do |pr|
        expect(pr.reviewer.id).not_to eq pr.reviewee.id
      end
    end

    it 'does not assign a student to review their own submission' do
      PeerReview.all.each do |pr|
        expect(pr.reviewer.does_not_share_any_students?(pr.reviewee)).to be_truthy
      end
    end

    # it 'random assigns properly' dp
    #   expect(PeerReview.where(result: Result.all).size).to eq 3
    # end

    it 'assigns all selected reviewer groups' do
      expect(@assignment_with_pr.peer_reviews.count).to be @selected_reviewer_group_ids.count
    end

    context 'download CSV' do
      before :each do
        @num_peer_reviews = PeerReview.all.count

        # Remember who was assigned to who before comparing
        @pr_expected_lines = Set.new
        @assignment_with_pr.peer_reviews.each do |pr|
          @pr_expected_lines.add("#{pr.reviewer.group.group_name},#{pr.reviewee.group.group_name}")
        end

        # Perform downloading via GET
        get :download_reviewer_reviewee_mapping, params: { assignment_id: @pr_id }
        @downloaded_text = response.body
        @found_filename = response.header['Content-Disposition'].include?('filename="peer_review_group_to_group_mapping.csv"')
        @lines = @downloaded_text[0...-1].split("\n")
      end

      it 'has valid header' do
        expect(@found_filename).to be_truthy
      end

      it 'ends with \n' do
        expect(@downloaded_text[-1, 1]).to eql("\n")
      end

      it 'has the correct number of lines' do
        # Since we compress all the reviewees onto one line with the reviewer,
        # there should only be 'num reviewers' amount of lines
        expect(@lines.count).to be @selected_reviewer_group_ids.count
      end

      it 'all lines match with no duplicates' do
        # Make sure that they all match, and that we don't have any duplicates
        # by accident (ex: having 'group1,group2,group3' repeated two times)
        uniqueness_test_set = Set.new
        @lines.each do |line|
          uniqueness_test_set.add(line)
          expect(@pr_expected_lines.member?(line)).to be_truthy
        end
        expect(uniqueness_test_set.count).to be @num_peer_reviews
      end
    end

    context 'upload CSV' do
      before :each do
        get :download_reviewer_reviewee_mapping, params: { assignment_id: @pr_id }
        @downloaded_text = response.body
        PeerReview.all.destroy_all
        @path = File.join(self.class.fixture_path, TEMP_CSV_FILE_PATH)
        # Now allow uploading by placing the data in a temporary file and reading
        # the data back through 'uploading' (requires a clean database)
        File.open(@path, 'w') do |f|
          f.write(@downloaded_text)
        end
        csv_upload = fixture_file_upload(TEMP_CSV_FILE_PATH, 'text/csv')
        fixture_upload = fixture_file_upload(TEMP_CSV_FILE_PATH, 'text/csv')
        allow(csv_upload).to receive(:read).and_return(File.read(fixture_upload))

        post :csv_upload_handler, params: { assignment_id: @pr_id, peer_review_mapping: csv_upload, encoding: 'UTF-8' }
      end

      it 'has the correct number of groups' do
        expect(Grouping.all.size).to eq 6
      end

      it 'has the correct number of peer reviews' do
        expect(PeerReview.all.size).to eq 3
      end

      it 'temporary file is deleted' do
        File.delete(@path)
        expect(File.exist?(@path)).to be_falsey
      end
    end
  end

  context 'assign' do
    before :each do
      post :assign_groups,
           params: { actionString: 'assign',
                     selectedReviewerGroupIds: @selected_reviewer_group_ids,
                     selectedRevieweeGroupIds: @selected_reviewee_group_ids,
                     assignment_id: @pr_id,
           }
    end

    it 'creates the correct number of peer reviews' do
      expect(PeerReview.all.size).to eq (@selected_reviewee_group_ids.size * @selected_reviewer_group_ids.size)
    end

    it 'does not assign a reviewee group to review their own submission' do
      PeerReview.all.each do |pr|
        expect(pr.reviewer.id).not_to eq pr.reviewee.id
      end
    end

    it 'does not assign a student to review their own submission' do
      PeerReview.all.each do |pr|
        expect(pr.reviewer.does_not_share_any_students?(pr.reviewee)).to be_truthy
      end
    end
  end

  context 'unassign' do
    before :each do
      post :assign_groups,
           params: { actionString: 'assign',
                     selectedReviewerGroupIds: @selected_reviewer_group_ids,
                     selectedRevieweeGroupIds: @selected_reviewee_group_ids,
                     assignment_id: @pr_id,
           }
      @num_peer_reviews = PeerReview.all.count
    end

    context 'all reviewers for selected reviewees' do
      before :each do
        post :assign_groups,
             params: { actionString: 'unassign',
                       selectedRevieweeGroupIds: @selected_reviewee_group_ids[0],
                       assignment_id: @pr_id,
             }
      end
      it 'deletes the correct number of peer reviews' do
        expect(PeerReview.all.count).to eq @num_peer_reviews - @selected_reviewer_group_ids.size
      end
    end

    context 'selected reviewer for selected reviewees' do
      before :each do
        selected_group = {}
        selected_group[@selected_reviewer_group_ids[0]] = true
        selected = {}
        selected[@selected_reviewee_group_ids[1]] = selected_group
        post :assign_groups,
             params: { actionString: 'unassign',
                       electedReviewerInRevieweeGroups: selected,
                       assignment_id: @pr_id,
             }
      end

      it 'deletes the correct number of peer reviews' do
        expect(PeerReview.all.count).to eq @num_peer_reviews - 1
      end
    end
  end
end
