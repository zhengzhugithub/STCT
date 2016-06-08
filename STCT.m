function results = STCT(seq)
cleanupObj = onCleanup(@cleanupFun);
rand('state', 0);
set_tracker_param;
middle_layer = 32;
last_layer = 42;
% middle_layer = 17;
% last_layer = 21;
%% read images
num_z = 4;
im1_name = sprintf([data_path 'img/%0' num2str(num_z) 'd.jpg'], im1_id);
im1 = double(imread(im1_name));


if size(im1,3)~=3
    im1(:,:,2) = im1(:,:,1);
    im1(:,:,3) = im1(:,:,1);
end
%% extract roi and display
roi1 = ext_roi(im1, location, center_off,  roi_size, roi_scale_factor);
roi1 = impreprocess(roi1);

%% extract vgg feature

fsolver.net.set_net_phase('test');
feature_input = fsolver.net.blobs('data');
feature_blob4 = fsolver.net.blobs('conv4_3');
fsolver.net.set_input_dim([0, 1, 3, roi_size, roi_size]);
feature_input.set_data(single(roi1));
fsolver.net.forward_prefilled();
deep_feature1 = feature_blob4.get_data();
fea_sz = size(deep_feature1);
cos_win = single(hann(fea_sz(1)) * hann(fea_sz(2))');
% cos_img = single(hann(roi_size) * hann(roi_size)');
deep_feature1 = bsxfun(@times, deep_feature1, cos_win);
scale_param.train_sample = get_scale_sample(deep_feature1, scale_param.scaleFactors_train, scale_param.scale_window_train);
%% ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
%% initialization

spn.net.set_net_phase('train');

spn.net.set_input_dim([0, scale_param.number_of_scales_train, fea_sz(3), fea_sz(2), fea_sz(1)]);

%% prepare training samples

fs = -1:1;
% fs = 0;
roi1 = zeros(roi_size, roi_size, 3, length(fs));
map1 = zeros(fea_sz(1), fea_sz(2), 1, length(fs));

for i = 1:length(fs)
%     center_off = rand(1,2) * 200 - 100;
    f = roi_scale_factor * 1.08 ^fs(i);
    roi = ext_roi(im1, location, [0,0],  roi_size, f);
    roi = impreprocess(roi);
    roi1(:,:,:,i) = roi;
    map = GetMap(size(im1), fea_sz, roi_size, location, center_off, f, map_sigma_factor, 'trans_gaussian');
    map = permute(map, [2,1,3]);
    map1(:,:,:,i) = map;
end
fsolver.net.set_input_dim([0, length(fs), 3, roi_size, roi_size]);
feature_input.set_data(single(roi1));
fsolver.net.forward_from_to(0,middle_layer);

%% Iterations
last_loss = 0;
for i=1:max_iter

    spn.net.empty_net_param_diff();
    fsolver.net.empty_net_param_diff();
    pre_heat_map1 = fsolver.net.forward_from_to(middle_layer + 1, last_layer);
    scale_score = spn.net.forward({scale_param.train_sample});
    pre_heat_map = pre_heat_map1{1};
    scale_score = scale_score{1};
    diff_cnna = pre_heat_map-map1;
    diff_spn = (scale_score-scale_param.y)/length(scale_param.number_of_scales_train);
    fsolver.net.backward_from_to({single(diff_cnna)}, last_layer, middle_layer + 1);
    spn.net.backward({single(diff_spn)});
    if mod(i, 10) == 0
        1;
    end
    fsolver.apply_update();
    spn.apply_update();
    fprintf('Iteration %03d/%03d, CNN-A Loss %0.1f, SPN Loss %0.1f\n', i, max_iter, sum(abs(diff_cnna(:))), sum(abs(diff_spn(:))));  
%     if i == 80 && sum(abs(diff_cnna(:))) - last_loss <= 0
%         break;
%     end
    last_loss = sum(abs(diff_cnna(:)));
    if i == 1,  %first frame, create GUI
        figure('Name','Tracking Results');
    subplot(1,2,1);
       im_handle_init1 = imagesc(pre_heat_map(:,:,:,1));
       subplot(1,2,2);
       stem(scale_score);
       im_handle_init2 = gca;
    else
       set(im_handle_init1, 'CData', pre_heat_map(:,:,:,1));
       stem(im_handle_init2, scale_score);
    end
    drawnow;
end
%% ================================================================
%% initialize weight
fsolver.net.set_input_dim([0, 1, 3, roi_size, roi_size]);
positions = [];
close all
spn.net.set_input_dim([0, scale_param.number_of_scales_test, fea_sz(3), fea_sz(2), fea_sz(1)]);
start_frame = im1_id;
tic;
for im2_id = start_frame:end_id
    fsolver.net.set_net_phase('test');
    spn.net.set_net_phase('test');
    fprintf('Processing Img: %d/%d\t', im2_id, end_id);
    im2_name = sprintf([data_path 'img/%0' num2str(num_z) 'd.jpg'], im2_id);
    im2 = double(imread(im2_name));
    if size(im2,3)~=3
        im2(:,:,2) = im2(:,:,1);
        im2(:,:,3) = im2(:,:,1);
    end 
    %% extract roi and display
    [roi2, roi_pos, padded_zero_map, pad] = ext_roi(im2, location, center_off,  roi_size, roi_scale_factor);
    %% preprocess roi
    roi2 = impreprocess(roi2);

    pre_heat_map = fsolver.net.forward({single(roi2)});

    
    pre_heat_map = permute(pre_heat_map{1}, [2,1]);
    pre_heat_map = cos_win .* pre_heat_map;
    %% compute local confidence
    pre_heat_map_upscale = imresize(pre_heat_map, roi_pos(4:-1:3));
    pre_img_map = padded_zero_map;
    pre_img_map(roi_pos(2):roi_pos(2)+roi_pos(4)-1, roi_pos(1):roi_pos(1)+roi_pos(3)-1) = pre_heat_map_upscale;
    pre_img_map = pre_img_map(pad+1:end-pad, pad+1:end-pad);
    [center_y, center_x] = find(pre_img_map == max(pre_img_map(:)));
    center_x = mean(center_x);
    center_y = mean(center_y);
    %% local scale estimation
    move = max(pre_heat_map(:)) > 0.15;
    if move
        
        base_location = [center_x - location(3)/2, center_y - location(4)/2, location([3,4])];
        roi2 = ext_roi(im2, base_location, center_off, roi_size, roi_scale_factor);
        roi2 = impreprocess(roi2);
        feature_input.set_data(single(roi2));
        fsolver.net.forward_prefilled();
        deep_feature2 = feature_blob4.get_data();
        deep_feature2 = bsxfun(@times, deep_feature2, cos_win);
        scale_sample = get_scale_sample(deep_feature2, scale_param.scaleFactors_test, scale_param.scale_window_test);
        scale_score = spn.net.forward({scale_sample});
        scale_score = scale_score{1};
        
        [max_scale_score, recovered_scale]= max(scale_score);
        if max_scale_score > scale_param.scale_thr
            recovered_scale = scale_param.number_of_scales_test+1 - recovered_scale;
        else
            recovered_scale = (scale_param.number_of_scales_test+1)/2;
        end
        %% what if the scale prediction confidence is very low??
        % update the scale
        scale_param.currentScaleFactor = scale_param.scaleFactors_test(recovered_scale);
        target_sz = location([3, 4]) * scale_param.currentScaleFactor;       
        location = [center_x - floor(target_sz(1)/2), center_y - floor(target_sz(2)/2), target_sz(1), target_sz(2)];
    else
         recovered_scale = (scale_param.number_of_scales_test+1)/2;
        %% what if the scale prediction confidence is very low??
        % update the scale
        scale_param.currentScaleFactor = scale_param.scaleFactors_test(recovered_scale);
    end
    fprintf(' scale = %f\n', scale_param.scaleFactors_test(recovered_scale));
    %% Update lnet and gnet
    if recovered_scale ~= (scale_param.number_of_scales_test+1)/2 && max(pre_heat_map(:))> 0.02 
        %         l_off = location_last(1:2)-location(1:2);
        %         map2 = GetMap(size(im2), fea_sz, roi_size, floor(location), floor(l_off), roi_scale_factor, map_sigma_factor, 'trans_gaussian');
        roi2 = ext_roi(im2, location, center_off,  roi_size, roi_scale_factor);
        roi2 = impreprocess(roi2);
        feature_input.set_data(single(roi2));
        fsolver.net.forward_prefilled();
        
        deep_feature_scale = feature_blob4.get_data();
        deep_feature_scale = bsxfun(@times, deep_feature_scale, cos_win);
        
        spn.net.set_input_dim([0, scale_param.number_of_scales_train, fea_sz(3), fea_sz(2), fea_sz(1)]);
        spn.net.set_net_phase('train');
        spn.net.empty_net_param_diff();
        
        scale_param.train_sample = get_scale_sample(deep_feature_scale, scale_param.scaleFactors_train, scale_param.scale_window_train);
        train_scale_score = spn.net.forward({scale_param.train_sample});
        train_scale_score = train_scale_score{1};
        diff_spn = (train_scale_score-scale_param.y)/length(scale_param.number_of_scales_train);
        diff_spn = {single(diff_spn)};
        
        spn.net.backward(diff_spn);
        spn.apply_update();
        spn.net.set_input_dim([0, scale_param.number_of_scales_test, fea_sz(3), fea_sz(2), fea_sz(1)]);
    end
    %% update with different strategies for different feature maps
    if  im2_id < start_frame -1 + 30 && max(pre_heat_map(:))> 0.15 && rand(1) > 0.3 || im2_id < start_frame -1 + 6
        update = true;
%     elseif im2_id >= start_frame -1 + 30 && move && max(pre_heat_map(:))> 0.2 && rand(1) > 0.3
    elseif im2_id >= start_frame -1 + 30 && move && max(pre_heat_map(:))> 0.2 && max(pre_heat_map(:)) < 0.4
            update = true;
    else
        update = false;
    end
    if  update
        roi2 = ext_roi(im2, location, center_off,  roi_size, roi_scale_factor);
        roi2 = impreprocess(roi2);     
        
        roi2 = cat(4, roi2, roi1(:,:,:,ceil(length(fs)/2)));
        
        map2 = GetMap(size(im2), fea_sz, roi_size, floor(location), floor(center_off), roi_scale_factor, map_sigma_factor, 'trans_gaussian');
        map2 = permute(map2, [2,1,3]);
        map2 = cat(4, map2, map1(:,:,:,ceil(length(fs)/2)));
        fsolver.net.set_input_dim([0, 2, 3, roi_size, roi_size]);
        fsolver.net.set_net_phase('train');
        feature_input.set_data(single(roi2));
        for ii = 1:2
            fsolver.net.empty_net_param_diff();
            pre_heat_map_train = fsolver.net.forward_from_to(middle_layer + 1, last_layer);
            pre_heat_map_train = pre_heat_map_train{1};
            diff_cnna2 = (pre_heat_map_train-map2);
            %
            fsolver.net.backward_from_to({single(diff_cnna2)}, last_layer, middle_layer + 1);
            %% first frame
%             pre_heat_map_train = fsolver.net.forward({single(roi1(:,:,:,4))});
%             pre_heat_map_train = pre_heat_map_train{1};
%             diff_cnna1 = 0.5*(pre_heat_map_train-map1(:,:,:,4));
%             fsolver.net.backward({diff_cnna1});
            fsolver.apply_update();
        end
        fsolver.net.set_net_phase('test');
        fsolver.net.set_input_dim([0, 1, 3, roi_size, roi_size]);
        %% add feature maps
    end
    positions = [positions; location];
    % Drwa resutls
    if im2_id == start_frame,  %first frame, create GUI
        figure('Name','Tracking Results');
        im_handle = imshow(uint8(im2), 'Border','tight', 'InitialMag', 100 + 100 * (length(im2) < 500));
        rect_handle = rectangle('Position', location, 'EdgeColor','r', 'linewidth', 2);
        text_handle = text(10, 10, sprintf('#%d / %d',im2_id, end_id));
        set(text_handle, 'color', [1 1 0], 'fontsize', 16, 'fontweight', 'bold');
        figure('Name','Tracking Results');
        subplot(1,2,1);
        im_handle_init1 = imshow(pre_heat_map);
        subplot(1,2,2);
        stem(scale_score);
        im_handle_init2 = gca;
    else
        set(im_handle, 'CData', uint8(im2))
        set(rect_handle, 'Position', location)
        set(text_handle, 'string', sprintf('#%d / %d',im2_id, end_id));
        set(im_handle_init1, 'CData', pre_heat_map)
        stem(im_handle_init2, scale_score);
    end

        
        drawnow
    fprintf('\n');
end
t = toc;
results.type = 'rect';
results.res = positions;
%  save([track_res  lower(set_name) '_fct_scale_base1.mat'], 'results');
fprintf('Speed: %0.3f fps\n', end_id/t);
end










